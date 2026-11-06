// The visibility walk of a frame (VisibleFrame::Process) on three cores: render.cfg vis_threads=1. Included by VisibleFrame.cpp only
// (apply_fixes.sh #72).
//
// The BSP clipper's screen is cut into three vertical strips. Each core walks the whole BSP front to back with a clipper of its own
// that sees only its strip (the rest of the screen is filled at the start), doing what ProcessNode / ProcessNodeSurface ask of the
// clipper in the same order: the node boxes, the surfaces (CheckSurface, CheckPortal) and the actors' boxes. A clipper's lines are
// independent of each other and a span is visible when some part of it is open, so "visible" for the whole screen is "visible in some
// strip", and what a strip closes is exactly the part of a span inside it. A strip that finds a node's box hidden skips the subtree,
// as the whole clipper would; its surfaces are inside the box (the render bounds of a node enclose its subtree: checked once per
// level, see BoundsNest), so they would have closed nothing in that strip. The strips write down every answer by node.
//
// Then the main thread walks the BSP as before (ProcessNode with VitaReplay set): the actors, portals and node lists are made
// exactly as before, in the same order, but every question to the clipper is answered from the strips. The actors of a node a strip
// skipped are tested in that strip at the moment it skipped the node (its clipper does not change inside the subtree it skips).
// What the strips cannot know is a warp zone that makes its other side when first seen (the Generate event): when the main walk finds
// a surface treated otherwise than the strips guessed, the frame is walked again the old way.
//
// Not exactly the same in one case: a node whose box is seen in one strip only, whose polygon reaches a pixel past its box's
// rounding into another strip. That strip then has that pixel open where the whole clipper closed it: it may call something visible
// that is hidden (drawn for nothing), never the other way round.

#ifdef __vita__
#include "VitaJobs.h"
#include "VitaStats.h"
#include "Packages/Engine/Actors/Info/UWarpZoneInfo.h"
#include "Packages/Engine/Actors/Info/USkyZoneInfo.h"
#include <psp2/kernel/processmgr.h>

// parallel_vis=1: the visibility walk on three cores (needs mesh_threads=2: its workers). Measured 2026-11-05 in Lev_Tut1 (before #82)
// each strip took as long as the whole walk on one core (8.3 ms: every strip still projects nearly every polygon, only the spans are
// split), the frame got slower. (The old key vis_threads, 1 in the render.cfg already on the Vita, is no longer read.)
// parallel_vis=2: auto, both ways are timed where the player is and the faster one is used (VitaVis::Auto).
inline int VitaVisMode() { static const int mode = std::clamp(VitaConfigInt("parallel_vis", 0), 0, 2); return mode; }

namespace VitaVis
{
	enum { Strips = 3 };
	enum : uint8_t { NodeNotReached = 0, NodeHidden = 1, NodeVisited = 2 };
	enum : uint8_t { SurfNone = 0, SurfHidden = 1, SurfVisible = 3, SurfPortal = 4 };

	struct ActorAnswer
	{
		UActor* actor;
		bool visible;
	};
	struct PortalAnswer
	{
		int node;
		uint32_t first, end;   // its spans in Strip::spans
	};
	struct StackEntry
	{
		int node;
		uint8_t phase;
		bool swap;
	};

	struct Strip
	{
		BspClipper clipper;
		int x0 = 0, x1 = 0;
		std::vector<uint8_t> state;            // by node
		std::vector<uint8_t> surf;             // by node (each node of a coplanar chain is checked once)
		std::vector<int32_t> actorFirst;       // by node: its actors' answers in actors, -1 = none written
		std::vector<uint16_t> actorCount;
		std::vector<ActorAnswer> actors;
		std::vector<PortalAnswer> portals;
		std::vector<PortalSpan> spans;
		std::vector<StackEntry> stack;
		std::vector<int> walk;
		vec3 points[256];
		double us = 0.0;
	};

	// What the strips need to know of the frame (filled by the main thread before they start)
	struct Context
	{
		VisibleFrame* frame = nullptr;
		UModel* model = nullptr;
		mat4 worldToProjection;
		const Array<PortalSpan>* portalSpans = nullptr;
		vec4 portalPlane;
		vec4 viewLocation;
		vec3 eye;
		bool mirror = false;
		int portalDepth = 0;
		std::vector<uint8_t> skyZone;          // by zone: the zone has a sky zone (a fake backdrop there is a sky portal)
		std::vector<uint8_t> warpReady;        // by zone: a warp zone with its other side
	};

	inline Strip* strips[Strips] = {};
	inline Context context;
	inline float shares[Strips] = { 1.0f / 3, 1.0f / 3, 1.0f / 3 };   // of the clipper's width, balanced by the strips' times

	// Once per level: does every node's render bound enclose the polygons of its subtree (and its coplanar nodes)? The strips depend on it
	inline UModel* checkedModel = nullptr;
	inline bool boundsNest = false;
	// The box each strip tests a node by: its render bound, grown where needed to enclose its subtree's polygons (some levels' render
	// bounds don't: Lev_Tut1 has 141 of 3324 short by up to 256 units). A grown box only hides less, never more.
	inline std::vector<BBox> walkBox;

	inline double NowUs() { return (double)sceKernelGetProcessTimeWide(); }

	// parallel_vis=2: Trial walks of each kind (every walk: the frame's and its sky / mirror / warp frames), then the faster is held
	struct Auto
	{
		enum { TrialWalks = 48, HoldWalks = 1200 };
		int phase = 0;              // 0: trying the old way, 1: trying the strips, 2: holding the choice
		int count = 0;
		double serialUs = 0.0, parallelUs = 0.0;
		bool useParallel = false;
		bool decided = false;
		double walkStart = 0.0;
	};
	inline Auto autoMode;

	// Whether this walk should try the strips
	inline bool WantParallel()
	{
		switch (VitaVisMode())
		{
		case 0: return false;
		case 1: return true;
		default: return autoMode.phase == 1 || (autoMode.phase == 2 && autoMode.useParallel);
		}
	}

	inline bool BoundsNest(UModel* model)
	{
		if (checkedModel == model)
			return boundsNest;
		checkedModel = model;
		const int count = (int)model->Nodes.size();
		std::vector<BBox> box(count);
		std::vector<uint8_t> has(count, 0);
		walkBox.assign(count, BBox());
		// post order: children before their parent
		std::vector<std::pair<int, bool>> stack;
		if (count > 0)
			stack.push_back({ 0, false });
		int bad = 0, checked = 0;
		float worst = 0.0f;
		while (!stack.empty())
		{
			auto [n, childrenDone] = stack.back();
			BspNode& node = model->Nodes[n];
			if (!childrenDone)
			{
				stack.back().second = true;
				if (node.Front >= 0) stack.push_back({ node.Front, false });
				if (node.Back >= 0) stack.push_back({ node.Back, false });
				continue;
			}
			stack.pop_back();
			BBox b;
			bool any = false;
			auto add = [&](const BBox& o)
			{
				if (!any) { b = o; any = true; return; }
				b.min = vec3(std::min(b.min.x, o.min.x), std::min(b.min.y, o.min.y), std::min(b.min.z, o.min.z));
				b.max = vec3(std::max(b.max.x, o.max.x), std::max(b.max.y, o.max.y), std::max(b.max.z, o.max.z));
			};
			int guard = 0;
			for (int p = n; p >= 0 && guard < 4096; p = model->Nodes[p].Plane, guard++)
			{
				const BspNode& poly = model->Nodes[p];
				if (poly.NumVertices >= 3 && poly.Surf >= 0)
				{
					const BspVert* v = &model->Vertices[poly.VertPool];
					for (int j = 0; j < poly.NumVertices; j++)
						add(BBox(model->Points[v[j].Vertex], model->Points[v[j].Vertex]));
				}
			}
			if (node.Front >= 0 && has[node.Front]) add(box[node.Front]);
			if (node.Back >= 0 && has[node.Back]) add(box[node.Back]);
			box[n] = b;
			has[n] = any;
			if (any && node.RenderBound >= 0 && node.RenderBound < (int)model->Bounds.size())
			{
				checked++;
				const BBox& r = model->Bounds[node.RenderBound];
				const float excess = std::max({ r.min.x - b.min.x, r.min.y - b.min.y, r.min.z - b.min.z, b.max.x - r.max.x, b.max.y - r.max.y, b.max.z - r.max.z });
				walkBox[n] = r;
				if (excess > 1.0f)
				{
					bad++;
					worst = std::max(worst, excess);
					walkBox[n].min = vec3(std::min(r.min.x, b.min.x), std::min(r.min.y, b.min.y), std::min(r.min.z, b.min.z));
					walkBox[n].max = vec3(std::max(r.max.x, b.max.x), std::max(r.max.y, b.max.y), std::max(r.max.z, b.max.z));
				}
			}
			else if (node.RenderBound >= 0 && node.RenderBound < (int)model->Bounds.size())
				walkBox[n] = model->Bounds[node.RenderBound];
		}
		boundsNest = true;
		LogMessage("VitaParallelVis: render bounds of " + std::to_string(checked) + " nodes checked: " +
			(bad == 0 ? std::string("each encloses its subtree") :
				std::to_string(bad) + " do not (by up to " + std::to_string((int)worst) + " units), the strips test those grown to their subtree") +
			"; the walk runs on three cores");
		return boundsNest;
	}

	inline void RecordActors(Strip& s, BspNode* node, int n)
	{
		if (!node->ActorList)
			return;
		s.actorFirst[n] = (int32_t)s.actors.size();
		uint16_t k = 0;
		for (UActor* actor = node->ActorList; actor != nullptr; actor = actor->BspInfo.Next, k++)
			s.actors.push_back({ actor, s.clipper.IsAABBVisible(actor->BspInfo.BoundingBox) });
		s.actorCount[n] = k;
	}

	// A subtree the strip skips: its actors are tested now (the clipper stays as it is while the subtree would be walked)
	inline void WalkSkipped(Strip& s, BspNode* nodes, int root)
	{
		s.walk.clear();
		s.walk.push_back(root);
		while (!s.walk.empty())
		{
			const int n = s.walk.back();
			s.walk.pop_back();
			BspNode* node = nodes + n;
			RecordActors(s, node, n);
			if (node->Front >= 0) s.walk.push_back(node->Front);
			if (node->Back >= 0) s.walk.push_back(node->Back);
		}
	}

	// What VisibleFrame::ProcessNodeSurface asks of the clipper, for one node of a coplanar chain
	inline void Surface(const Context& c, Strip& s, BspNode* nodes, int n, bool front)
	{
		BspNode* node = nodes + n;
		if (node->NumVertices < 3 || node->Surf < 0)
			return;
		UModel* model = c.model;
		const BspSurface& surface = model->Surfaces[node->Surf];
		const uint32_t PolyFlags = surface.PolyFlags | (surface.Material ? surface.Material->PolyFlags() : 0);   // (a read of a property)
		const vec4 plane(node->PlaneX, node->PlaneY, node->PlaneZ, -node->PlaneW);
		if (!(PolyFlags & PF_TwoSided) && dot(c.viewLocation, plane) < 0.0f)
			return;

		const int numverts = node->NumVertices;
		vec3* points = s.points;
		const BspVert* v = &model->Vertices[node->VertPool];
		if (c.mirror)
		{
			for (int j = 0; j < numverts; j++)
				points[numverts - 1 - j] = model->Points[v[j].Vertex];
		}
		else
		{
			for (int j = 0; j < numverts; j++)
				points[j] = model->Points[v[j].Vertex];
		}

		auto portal = [&]()
		{
			PortalAnswer answer;
			answer.node = n;
			answer.first = (uint32_t)s.spans.size();
			Array<PortalSpan> spans = s.clipper.CheckPortal(points, numverts);
			s.spans.insert(s.spans.end(), spans.begin(), spans.end());
			answer.end = (uint32_t)s.spans.size();
			s.portals.push_back(answer);
			s.surf[n] = SurfPortal;
		};

		if (c.portalDepth < 4)
		{
			if ((PolyFlags & (PF_FakeBackdrop | PF_Invisible)) == PF_FakeBackdrop)
			{
				const int zone = front ? node->Zone1 : node->Zone0;
				if (zone >= 0 && zone < (int)c.skyZone.size() && c.skyZone[zone])
				{
					portal();
					return;
				}
			}
			else if (PolyFlags & PF_Portal)
			{
				const bool eyeBehind = dot(vec4(c.eye, 1.0f), plane) < 0.0f;
				const int portalZone = eyeBehind ? node->Zone1 : node->Zone0;
				if (portalZone > 0 && portalZone < (int)c.warpReady.size() && c.warpReady[portalZone])
				{
					if (eyeBehind)
						std::reverse(points, points + numverts);
					portal();
					return;
				}
			}
			else if (PolyFlags & PF_Mirrored)
			{
				if (c.portalDepth >= 3)
					return;
				if (c.portalDepth > 0 && dot(c.eye - model->Points[surface.pBase], model->Vectors[surface.vNormal]) <= 0.0f)
					return;
				portal();
				return;
			}
		}

		s.surf[n] = s.clipper.CheckSurface(points, numverts, (PolyFlags & PF_NoOcclude) == 0) ? SurfVisible : SurfHidden;
	}

	// One strip's walk: VisibleFrame::ProcessNode's order, without recursion (the workers have small stacks)
	inline void Run(void*, int index)
	{
		const double started = NowUs();
		const Context& c = context;
		Strip& s = *strips[index];
		BspNode* nodes = c.model->Nodes.data();

		// its clipper: open only in its columns; its answers: none yet
		const size_t count = c.model->Nodes.size();
		s.clipper.numDrawSpans = s.clipper.numSurfs = s.clipper.numTris = 0;
		s.clipper.Setup(c.worldToProjection, *c.portalSpans, c.portalPlane);
		s.clipper.VitaKeepColumns(s.x0, s.x1);
		s.state.assign(count, NodeNotReached);
		s.surf.assign(count, SurfNone);
		s.actorFirst.assign(count, -1);
		s.actorCount.assign(count, 0);
		s.actors.clear();
		s.portals.clear();
		s.spans.clear();

		s.stack.clear();
		s.stack.push_back({ 0, 0, false });
		while (!s.stack.empty())
		{
			const StackEntry e = s.stack.back();
			BspNode* node = nodes + e.node;
			if (e.phase == 0)
			{
				const bool visible = node->RenderBound == -1 || s.clipper.IsAABBVisible(walkBox[e.node]);
				if (!visible)
				{
					s.state[e.node] = NodeHidden;
					s.stack.pop_back();
					WalkSkipped(s, nodes, e.node);
					continue;
				}
				s.state[e.node] = NodeVisited;
				RecordActors(s, node, e.node);
				const vec4 plane(node->PlaneX, node->PlaneY, node->PlaneZ, -node->PlaneW);
				const bool swap = dot(c.viewLocation, plane) < 0.0f;
				const int front = swap ? node->Back : node->Front;
				s.stack.back().phase = 1;
				s.stack.back().swap = swap;
				if (front >= 0)
					s.stack.push_back({ front, 0, false });
			}
			else if (e.phase == 1)
			{
				for (int p = e.node;;)
				{
					Surface(c, s, nodes, p, e.swap);
					if (nodes[p].Plane < 0)
						break;
					p = nodes[p].Plane;
				}
				const int back = e.swap ? node->Front : node->Back;
				s.stack.back().phase = 2;
				if (back >= 0)
					s.stack.push_back({ back, 0, false });
			}
			else
			{
				s.stack.pop_back();
			}
		}
		s.us = NowUs() - started;
	}
}

// The frame's walk on three cores; false: walk it the old way (ProcessNode with the frame's own clipper)
bool VisibleFrame::VitaProcessParallel(const Array<PortalSpan>& portalSpans, const vec4& portalPlane)
{
	using namespace VitaVis;
	UModel* model = engine->Level->Model;
	autoMode.walkStart = NowUs();
	if (!WantParallel() || VitaJobs::Mode() < 2 || !VitaJobs::Start() || engine->LaunchInfo.IsHarryPotter2() || model->Nodes.empty() ||
		!BoundsNest(model))
	{
		VitaStats::visSerial++;
		return false;
	}

	Context& c = context;
	c.frame = this;
	c.model = model;
	c.worldToProjection = Frame.Projection * Frame.WorldToView * Frame.ObjectToWorld;
	c.portalSpans = &portalSpans;
	c.portalPlane = portalPlane;
	c.viewLocation = ViewLocation;
	c.eye = EyeLocation();
	c.mirror = MirrorFlag;
	c.portalDepth = PortalDepth;

	// The zones as ProcessNodeSurface sees them now (the strips do not call into the engine; they only read)
	const int zones = (int)model->Zones.size();
	c.skyZone.assign(zones, 0);
	c.warpReady.assign(zones, 0);
	for (int z = 0; z < zones; z++)
	{
		UZoneInfo* zoneInfo = engine->GetZoneActor(z);
		c.skyZone[z] = zoneInfo && zoneInfo->SkyZone() ? 1 : 0;
		UWarpZoneInfo* warpZone = UObject::TryCast<UWarpZoneInfo>(zoneInfo);
		c.warpReady[z] = warpZone && warpZone->OtherSideActor() && warpZone->OtherSideLevel() ? 1 : 0;
	}

	// The strips' borders, from the shares
	const int width = Clipper.VitaWidth();
	int border = 0;
	for (int i = 0; i < Strips; i++)
	{
		if (!strips[i])
			strips[i] = new Strip();
		Strip& s = *strips[i];
		s.x0 = border;
		s.x1 = i == Strips - 1 ? width : std::clamp(border + (int)(shares[i] * width + 0.5f), border + 16, width - 16 * (Strips - 1 - i));
		border = s.x1;
		if (i < Strips - 1)
			VitaStats::visSplit[i] = s.x1;
	}

	// The settings the strips' code reads are made here first: a function's static is made under a lock of libstdc++, which waits through
	// pthreads, and the workers are kernel threads without pthread data: a worker that has to wait for one crashed (data abort in
	// pte_osSemaphoreCancellablePend, the main thread reading render.cfg for VitaClipperPolygons in its own strip)
	(void)VitaClipperPolygons();
	(void)VitaClipperWidth();
	(void)VitaClipperHeight();

	VitaJobs::Run(&VitaVis::Run, nullptr, Strips);

	// The shares follow the strips' times (half way each frame): the slower strips get narrower
	{
		float cost[Strips], total = 0.0f;
		for (int i = 0; i < Strips; i++)
		{
			const float w = (float)std::max(strips[i]->x1 - strips[i]->x0, 1);
			cost[i] = std::max((float)strips[i]->us, 1.0f) / w;   // time per column
			VitaStats::visStripUs[i] += strips[i]->us;
		}
		float want[Strips];
		for (int i = 0; i < Strips; i++)
		{
			want[i] = 1.0f / cost[i];
			total += want[i];
		}
		for (int i = 0; i < Strips; i++)
			shares[i] = std::clamp(0.5f * shares[i] + 0.5f * want[i] / total, 0.08f, 0.8f);
		const float sum = shares[0] + shares[1] + shares[2];
		for (int i = 0; i < Strips; i++)
			shares[i] /= sum;
	}

	// The main walk with the strips' answers
	const double replayStarted = NowUs();
	VitaReplay = true;
	VitaReplayFailed = false;
	ProcessNode(&model->Nodes[0]);
	VitaReplay = false;
	for (int i = 0; i < Strips; i++)
	{
		Clipper.numTris += strips[i]->clipper.numTris;
		Clipper.numDrawSpans += strips[i]->clipper.numDrawSpans;
	}
	VitaStats::visReplayUs += NowUs() - replayStarted;
	VitaStats::visFrames++;

	if (VitaReplayFailed)
	{
		// What the strips guessed was wrong for some surface: everything again the old way, as a new frame for the actors
		static int logged = 0;
		if (logged++ < 5)
			LogMessage("VitaParallelVis: a surface was not what the strips took it for (a warp zone that just made its other side?): this frame is walked again the old way");
		VitaStats::visRedone++;
		OpaqueNodes.clear();
		Actors.clear();
		Translucents.clear();
		Coronas.clear();
		Portals.clear();
		FrameCounter = engine->render->FrameCounter++;
		Clipper.Setup(c.worldToProjection, portalSpans, portalPlane);
		ProcessNode(&model->Nodes[0]);
	}
	return true;
}

bool VisibleFrame::VitaReplayBox(BspNode* node)
{
	const int n = (int)(node - engine->Level->Model->Nodes.data());
	for (int i = 0; i < VitaVis::Strips; i++)
	{
		if (VitaVis::strips[i]->state[n] == VitaVis::NodeVisited)
			return true;
	}
	return false;
}

int VisibleFrame::VitaReplayActor(BspNode* node, int k, UActor* actor)
{
	const int n = (int)(node - engine->Level->Model->Nodes.data());
	bool visible = false;
	for (int i = 0; i < VitaVis::Strips; i++)
	{
		const VitaVis::Strip& s = *VitaVis::strips[i];
		if (s.actorFirst[n] < 0 || k >= (int)s.actorCount[n] || s.actors[s.actorFirst[n] + k].actor != actor)
		{
			VitaReplayFailed = true;   // the node's actors changed since the strips looked
			return 1;
		}
		visible |= s.actors[s.actorFirst[n] + k].visible;
	}
	return visible ? 1 : 0;
}

bool VisibleFrame::VitaReplaySurface(BspNode* node)
{
	const int n = (int)(node - engine->Level->Model->Nodes.data());
	bool visible = false;
	for (int i = 0; i < VitaVis::Strips; i++)
	{
		const uint8_t answer = VitaVis::strips[i]->surf[n];
		if (answer == VitaVis::SurfPortal)
			VitaReplayFailed = true;
		visible |= answer == VitaVis::SurfVisible;
	}
	return visible;
}

Array<PortalSpan> VisibleFrame::VitaReplayPortal(BspNode* node)
{
	const int n = (int)(node - engine->Level->Model->Nodes.data());
	Array<PortalSpan> spans;
	for (int i = 0; i < VitaVis::Strips; i++)
	{
		const VitaVis::Strip& s = *VitaVis::strips[i];
		const uint8_t answer = s.surf[n];
		if (answer == VitaVis::SurfHidden || answer == VitaVis::SurfVisible)
		{
			VitaReplayFailed = true;
			continue;
		}
		if (answer != VitaVis::SurfPortal)
			continue;
		for (const VitaVis::PortalAnswer& p : s.portals)
		{
			if (p.node == n)
			{
				spans.insert(spans.end(), s.spans.begin() + p.first, s.spans.begin() + p.end);
				break;
			}
		}
	}
	return spans;
}
// After every walk (VisibleFrame::Process, apply_fixes #83): its time, for parallel_vis=2
void VitaVisWalkDone(bool parallel)
{
	using namespace VitaVis;
	if (VitaVisMode() != 2)
		return;
	Auto& a = autoMode;
	const double us = NowUs() - a.walkStart;
	if (a.phase == 0)
		a.serialUs += us;
	else if (a.phase == 1)
	{
		if (!parallel)   // the strips could not run (no workers): the old way it is
		{
			a.phase = 2;
			a.count = 0;
			a.useParallel = false;
			return;
		}
		a.parallelUs += us;
	}
	if (++a.count < (a.phase == 2 ? (int)Auto::HoldWalks : (int)Auto::TrialWalks))
		return;
	a.count = 0;
	if (a.phase < 2)
	{
		a.phase++;
		if (a.phase == 2)
		{
			const bool faster = a.parallelUs < a.serialUs * 0.95;   // a clear gain only
			if (!a.decided || faster != a.useParallel)
				LogMessage("VitaParallelVis auto: " + std::to_string(a.serialUs / Auto::TrialWalks / 1000.0) + " ms a walk on one core, " +
					std::to_string(a.parallelUs / Auto::TrialWalks / 1000.0) + " ms on three: " + (faster ? "three cores" : "one core"));
			a.useParallel = faster;
			a.decided = true;
		}
	}
	else
	{
		a.phase = 0;   // measure again where the player is now
		a.serialUs = a.parallelUs = 0.0;
	}
}
#endif