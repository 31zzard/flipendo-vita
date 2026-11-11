// The main view's BSP walk replayed while the view does not change (apply_fixes.sh #212), included in Render/VisibleFrame.cpp.
//
// VisibleFrame::Process walks the level's BSP for every frame: node boxes and surfaces projected into the clipper (BspClipper),
// 10-16 ms a frame in HP1's heavy halls. Standing still, the main view is bit for bit the one of the frame before (VitaViewSame:
// 600 of 600 in Lev3_Intro). The walk is then the same: the level's BSP and its surfaces do not change, and the clipper is only
// filled by surfaces and portals (VisibleActor tests actors against it, and fills nothing; a mover's mirror does fill it:
// VisibleBrush marks such a walk spoiled). So a full walk records what happened, in order (the event log below), and the next
// frame with the same view walks the BSP again with those answers: the node box and surface tests are not made, the spans each
// surface filled are filled again at the same point of the walk (so the clipper is, at every point, what it was), and the
// actors in the nodes are tested live against it as before (they move). Everything else (the node, actor, translucent and
// portal lists, every early decision of ProcessNodeSurface) is made as before. Each replayed event must be the one expected
// (the same node, the same surface flags); else the frame is walked again from the start, the full way (a new FrameCounter,
// as VitaParallelVis.inc does).
//
// render.cfg view_replay=0: never. view_replay_check=1: never replayed; a view equal to the logged one is walked the full way
// and its log compared with the logged one (log 'VitaViewReplay check: N walks compared, M differ').
//
// Events (uint64_t; the type in the top 4 bits):
//   1 BOX     node, answer << 32                  node box test (ProcessNode)
//   2 SURF    node, answer << 32                  CheckSurface of a node's surface, followed by
//   3 FLAGS   the surface's PolyFlags (surface | material), and
//   4 NFILL   n, then n x 5 FILL (y, x0, x1: 16 bits each) the clipper spans it filled
//   6 PORTAL  node                                a CheckPortal (sky, warp zone, mirror), followed by FLAGS,
//   7 NSPAN   n, then n x 8 SPAN (y, x0, x1) the spans it gave, and NFILL / FILL

#ifdef __vita__
#include "VitaViewReplay.h"
#include "VitaLevelEpoch.h"

namespace
{
	enum : uint64_t { EvBox = 1, EvSurf = 2, EvFlags = 3, EvNFill = 4, EvFill = 5, EvPortal = 6, EvNSpan = 7, EvSpan = 8 };
	inline uint64_t VitaEv(uint64_t type, uint64_t value) { return (type << 60) | (value & 0x0fffffffffffffffull); }
	inline uint64_t VitaEvType(uint64_t e) { return e >> 60; }

	int VitaViewMode()
	{
		static int mode = -2;   // -1 off, 0 on, 1 check
		if (mode == -2)
			mode = VitaConfigInt("view_replay", 1) == 0 ? -1 : (VitaConfigInt("view_replay_check", 0) != 0 ? 1 : 0);
		return mode;
	}

	uint32_t VitaSurfaceFlags(BspNode* node)
	{
		const BspSurface& surface = engine->Level->Model->Surfaces[node->Surf];
		uint32_t flags = surface.PolyFlags;
		if (surface.Material)
			flags |= surface.Material->PolyFlags();
		return flags;
	}

	std::vector<uint64_t> vitaFillTemp;
	std::vector<uint64_t> vitaCheckEvents;   // view_replay_check: the logged walk kept for the comparison
	unsigned vitaViewWalks = 0, vitaViewReplays = 0, vitaViewFailed = 0, vitaCheckWalks = 0, vitaCheckDiffer = 0;
}

// The next event of the replay, of this type; false (and the replay failed) when it is not
bool VisibleFrame::VitaViewNext(uint64_t type, uint64_t& value)
{
	VitaViewLog& log = vitaViewLog;
	if (VitaReplayFailed || log.pos >= log.events.size() || VitaEvType(log.events[log.pos]) != type)
	{
		VitaReplayFailed = true;
		return false;
	}
	value = log.events[log.pos++] & 0x0fffffffffffffffull;
	return true;
}

// The spans a replayed surface or portal filled, filled again
void VisibleFrame::VitaViewRefill()
{
	uint64_t n = 0;
	if (!VitaViewNext(EvNFill, n))
		return;
	for (uint64_t i = 0; i < n; i++)
	{
		uint64_t f = 0;
		if (!VitaViewNext(EvFill, f))
			return;
		Clipper.VitaFill((int16_t)(uint16_t)f, (int16_t)(uint16_t)(f >> 16), (int16_t)(uint16_t)(f >> 32));
	}
}

bool VisibleFrame::VitaViewReplayBox(BspNode* node)
{
	uint64_t v = 0;
	if (!VitaViewNext(EvBox, v) || (uint32_t)v != (uint32_t)(node - engine->Level->Model->Nodes.data()))
	{
		VitaReplayFailed = true;
		return false;
	}
	return (v >> 32) != 0;
}

bool VisibleFrame::VitaViewReplaySurface(BspNode* node)
{
	uint64_t v = 0, flags = 0;
	if (!VitaViewNext(EvSurf, v) || (uint32_t)v != (uint32_t)(node - engine->Level->Model->Nodes.data()) ||
		!VitaViewNext(EvFlags, flags) || (uint32_t)flags != VitaSurfaceFlags(node))
	{
		VitaReplayFailed = true;
		return false;
	}
	VitaViewRefill();
	return (v >> 32) != 0;
}

Array<PortalSpan> VisibleFrame::VitaViewReplayPortal(BspNode* node)
{
	Array<PortalSpan> spans;
	uint64_t v = 0, flags = 0, n = 0;
	if (!VitaViewNext(EvPortal, v) || (uint32_t)v != (uint32_t)(node - engine->Level->Model->Nodes.data()) ||
		!VitaViewNext(EvFlags, flags) || (uint32_t)flags != VitaSurfaceFlags(node) || !VitaViewNext(EvNSpan, n))
	{
		VitaReplayFailed = true;
		return spans;
	}
	for (uint64_t i = 0; i < n; i++)
	{
		uint64_t s = 0;
		if (!VitaViewNext(EvSpan, s))
			return spans;
		PortalSpan span;
		span.y = (int16_t)(uint16_t)s;
		span.x0 = (int16_t)(uint16_t)(s >> 16);
		span.x1 = (int16_t)(uint16_t)(s >> 32);
		spans.push_back(span);
	}
	VitaViewRefill();
	return spans;
}

// A node box test of a recorded walk
void VisibleFrame::VitaViewRecordBox(BspNode* node, bool visible)
{
	if (vitaViewLog.recording)
		vitaViewLog.events.push_back(VitaEv(EvBox, (uint64_t)(uint32_t)(node - engine->Level->Model->Nodes.data()) | ((uint64_t)visible << 32)));
}

// CheckSurface, recorded when the walk is
bool VisibleFrame::VitaViewCheckSurface(BspNode* node, const vec3* points, int numverts, bool solid)
{
	if (!vitaViewLog.recording)
		return Clipper.CheckSurface(points, numverts, solid);
	vitaFillTemp.clear();
	Clipper.VitaFillRecord = &vitaFillTemp;
	const bool visible = Clipper.CheckSurface(points, numverts, solid);
	Clipper.VitaFillRecord = nullptr;
	std::vector<uint64_t>& e = vitaViewLog.events;
	e.push_back(VitaEv(EvSurf, (uint64_t)(uint32_t)(node - engine->Level->Model->Nodes.data()) | ((uint64_t)visible << 32)));
	e.push_back(VitaEv(EvFlags, VitaSurfaceFlags(node)));
	e.push_back(VitaEv(EvNFill, vitaFillTemp.size()));
	for (uint64_t f : vitaFillTemp)
		e.push_back(VitaEv(EvFill, f));
	return visible;
}

// CheckPortal, recorded when the walk is
Array<PortalSpan> VisibleFrame::VitaViewCheckPortal(BspNode* node, const vec3* points, uint32_t count)
{
	if (!vitaViewLog.recording)
		return Clipper.CheckPortal(points, count);
	vitaFillTemp.clear();
	Clipper.VitaFillRecord = &vitaFillTemp;
	Array<PortalSpan> spans = Clipper.CheckPortal(points, count);
	Clipper.VitaFillRecord = nullptr;
	std::vector<uint64_t>& e = vitaViewLog.events;
	e.push_back(VitaEv(EvPortal, (uint64_t)(uint32_t)(node - engine->Level->Model->Nodes.data())));
	e.push_back(VitaEv(EvFlags, VitaSurfaceFlags(node)));
	e.push_back(VitaEv(EvNSpan, spans.size()));
	for (const PortalSpan& s : spans)
		e.push_back(VitaEv(EvSpan, VitaPackSpan((int)s.y, s.x0, s.x1)));
	e.push_back(VitaEv(EvNFill, vitaFillTemp.size()));
	for (uint64_t f : vitaFillTemp)
		e.push_back(VitaEv(EvFill, f));
	return spans;
}

// The main view's walk (VisibleFrame::Process): true when done here (replayed, or walked the full way and recorded)
bool VisibleFrame::VitaViewWalk()
{
	if (PortalDepth != 0 || MirrorFlag || VitaViewMode() < 0)
		return false;
	VitaViewLog& log = vitaViewLog;
	UModel* model = engine->Level->Model;
	const mat4 worldToProjection = Frame.Projection * Frame.WorldToView * Frame.ObjectToWorld;
	float key[19];
	std::memcpy(key, worldToProjection.matrix, 64);
	key[16] = ViewLocation.x;
	key[17] = ViewLocation.y;
	key[18] = ViewLocation.z;
	const bool sameView = log.valid && log.model == model && log.epoch == vitaLevelEpoch && std::memcmp(key, log.key, sizeof(key)) == 0;

	vitaViewWalks++;
	if (vitaViewWalks % 600 == 0)
	{
		LogMessage("VitaViewReplay: " + std::to_string(vitaViewReplays) + " of 600 main views replayed, " + std::to_string(vitaViewFailed) + " failed" +
			(VitaViewMode() == 1 ? "; check: " + std::to_string(vitaCheckWalks) + " walks compared, " + std::to_string(vitaCheckDiffer) + " differ" : std::string()));
		vitaViewReplays = vitaViewFailed = 0;
	}

	if (sameView && VitaViewMode() == 0)
	{
		vitaReplaySource = 1;
		VitaReplay = true;
		VitaReplayFailed = false;
		log.pos = 0;
		ProcessNode(&model->Nodes[0]);
		VitaReplay = false;
		vitaReplaySource = 0;
		if (!VitaReplayFailed && log.pos == log.events.size())
		{
			vitaViewReplays++;
			return true;
		}
		// Not what was logged: the whole walk again, the full way, as a new frame for the actors
		vitaViewFailed++;
		static int told = 0;
		if (told++ < 5)
			LogMessage("VitaViewReplay: the walk went otherwise than logged (event " + std::to_string(log.pos) + " of " + std::to_string(log.events.size()) + "): walked again the full way");
		OpaqueNodes.clear();
		Actors.clear();
		Translucents.clear();
		Coronas.clear();
		Portals.clear();
		FrameCounter = engine->render->FrameCounter++;
		Clipper.Setup(worldToProjection, {}, PortalPlane);
	}

	// The full walk, logged
	if (sameView && VitaViewMode() == 1)
		vitaCheckEvents.swap(log.events);
	log.events.clear();
	log.recording = true;
	log.spoiled = false;
	ProcessNode(&model->Nodes[0]);
	log.recording = false;
	if (sameView && VitaViewMode() == 1)
	{
		vitaCheckWalks++;
		if (vitaCheckEvents != log.events)
		{
			vitaCheckDiffer++;
			static int told = 0;
			if (told++ < 10)
				LogMessage("VitaViewReplay check: the same view walked otherwise (" + std::to_string(vitaCheckEvents.size()) + " / " + std::to_string(log.events.size()) + " events)");
		}
	}
	log.valid = !log.spoiled;
	log.model = model;
	log.epoch = vitaLevelEpoch;
	std::memcpy(log.key, key, sizeof(key));
	return true;
}
#endif
