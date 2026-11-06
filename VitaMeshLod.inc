// Included inside namespace KW in src/knowwonder/Anim/KWSkeletal.cpp, before DrawSkeletalMesh (vita/apply_fixes.sh #66).
//
// HP1's mesh LOD, read from the retail Render.dll (docs/re/engine/animation.md, "LOD"):
//   URender::DrawLodMesh [HP1 Render 0x10B0FF00]: when Mesh.LODStrength != 0 and Mesh.CollapsePointThus isn't empty,
//     factor     = Actor.LODBias / (LODAdjust * MeshLOD * Mesh.LODStrength)            (URender+0x50, +0x4C: 1.0)
//     area       = (X2 - X1 + 1) * (Y2 - Y1 + 1)                                       (the actor's FDynamicSprite rectangle)
//     v          = max(sqrt(area) / Frame.FX * 4, area * 0.04 / ModelVerts) * factor   (FSceneNode+0xB8 = FX)
//     LODRequest = min(round(LODMinVerts + (ModelVerts - LODMinVerts) * v), ModelVerts)
//   with URender+0x54 (the LOD mode) at its default 1. A face is drawn when FaceLevel[face] <= LODRequest; a wedge whose
//   vertex is at or above LODRequest is replaced by CollapseWedgeThus[wedge] until it isn't. Normals and light use the
//   same faces.
//   URender's per-frame update [HP1 Render 0x10B1EF80]: frameTime = min(seconds since the last frame, 0.2),
//     target = clamp(Client.MinDesiredFrameRate, 10, 120) * frameTime; LODAdjust steps by 0.1 a frame towards it, never under 1.
//   HP1's Default.ini has MinDesiredFrameRate=30 (render.cfg lod_min_fps).

static float VitaLodAdjust = 1.0f;
static unsigned VitaLodFrame = ~0u;
static double VitaLodLastMs = 0.0;
static std::unordered_set<const void*> VitaLodLogged;

static void VitaLodTick()
{
	if (VitaLodFrame == VitaTimers::frameNumber)
		return;
	VitaLodFrame = VitaTimers::frameNumber;
	const double now = VitaTimers::Now();
	float frameTime = VitaLodLastMs > 0.0 ? (float)((now - VitaLodLastMs) * 0.001) : 0.0f;
	VitaLodLastMs = now;
	if (frameTime > 0.2f)
		frameTime = 0.2f;
	static const float desired = std::clamp((float)VitaConfigInt("lod_min_fps", 30), 10.0f, 120.0f);
	const float target = desired * frameTime;
	float adjust;
	if (target > 1.0f)
	{
		adjust = VitaLodAdjust + 0.1f;
		if (adjust < 1.0f)
			adjust = 1.0f;
		else if (!(adjust < target))
			adjust = target;
	}
	else
	{
		adjust = VitaLodAdjust - 0.1f;
		if (adjust < 1.0f)
			adjust = 1.0f;
	}
	VitaLodAdjust = adjust;
	VitaStats::lodAdjust = adjust;
}

// The vertices the mesh is drawn with this frame, or -1 for all of them (no LOD data, a weapon, mesh_lod=0). The same for every
// call with the same frame, actor and mesh in one frame: the prepass and the drawing agree.
static int VitaLodRequest(VisibleFrame* frame, UActor* actor, USkeletalMesh* mesh)
{
	if (!VitaMeshLod() || !engine->LaunchInfo.IsHarryPotter1() || actor == WeaponDraw.Actor)
		return -1;

	const bool hasData = mesh->LODStrength != 0.0f && !mesh->CollapsePointThus.empty() && mesh->SpecialVerts == 0 && mesh->ModelVerts > 0 &&
		mesh->FaceLevel.size() == mesh->Faces.size() && !mesh->CollapseWedgeThus.empty();
	if (VitaLodLogged.insert(mesh).second)
	{
		LogMessage("Mesh LOD: " + mesh->Name.ToString() + " ModelVerts " + std::to_string(mesh->ModelVerts) + ", points " +
			std::to_string(mesh->Points.size()) + ", LODStrength " + std::to_string(mesh->LODStrength) + ", LODMinVerts " +
			std::to_string(mesh->LODMinVerts) + ", CollapsePointThus " + std::to_string(mesh->CollapsePointThus.size()) +
			", FaceLevel " + std::to_string(mesh->FaceLevel.size()) + "/" + std::to_string(mesh->Faces.size()) + " faces, SpecialVerts " +
			std::to_string(mesh->SpecialVerts) + (hasData ? "" : ": drawn in full"));
	}
	if (!hasData)
		return -1;

	VitaLodTick();

	// The actor's rectangle on the screen: its render box through the frame's projection, inside the frame
	const SceneNode& f = frame->Frame;
	const BBox& box = actor->BspInfo.BoundingBox;
	const mat4 toClip = f.Projection * f.WorldToView;
	float minX = 1e30f, minY = 1e30f, maxX = -1e30f, maxY = -1e30f;
	bool behind = false;
	for (int i = 0; i < 8 && !behind; i++)
	{
		const vec3 corner((i & 1) ? box.max.x : box.min.x, (i & 2) ? box.max.y : box.min.y, (i & 4) ? box.max.z : box.min.z);
		const vec4 c = toClip * vec4(corner, 1.0f);
		if (c.w <= 0.001f)
		{
			behind = true;
			break;
		}
		const float x = (c.x / c.w + 1.0f) * 0.5f * f.FX;
		const float y = (1.0f - c.y / c.w) * 0.5f * f.FY;
		minX = std::min(minX, x);
		maxX = std::max(maxX, x);
		minY = std::min(minY, y);
		maxY = std::max(maxY, y);
	}
	const int width = std::max((int)f.FX, 1), height = std::max((int)f.FY, 1);
	int x1 = 0, y1 = 0, x2 = width - 1, y2 = height - 1;   // a box reaching behind the eye covers the frame
	if (!behind)
	{
		x1 = std::clamp((int)std::floor(minX), 0, width - 1);
		x2 = std::clamp((int)std::floor(maxX), 0, width - 1);
		y1 = std::clamp((int)std::floor(minY), 0, height - 1);
		y2 = std::clamp((int)std::floor(maxY), 0, height - 1);
	}
	const float area = (float)(x2 - x1 + 1) * (float)(y2 - y1 + 1);

	const float modelVerts = (float)mesh->ModelVerts;
	const float factor = actor->LODBias() / (VitaLodAdjust * 1.0f * mesh->LODStrength);
	const float bySize = std::sqrt(area) / f.FX * 4.0f;
	const float byDensity = area * 0.04f / modelVerts;
	const float v = std::max(bySize, byDensity) * factor;
	const float request = (float)((int)mesh->ModelVerts - (int)mesh->LODMinVerts) * v + (float)mesh->LODMinVerts;
	long lod = std::lrint(request);
	if (lod > (long)mesh->ModelVerts)
		lod = (long)mesh->ModelVerts;
	if (lod < 0)
		lod = 0;

	VitaStats::lodMeshes++;
	VitaStats::lodVerts += (double)lod;
	VitaStats::lodModelVerts += modelVerts;
	return lod >= (long)mesh->ModelVerts ? -1 : (int)lod;
}

// A wedge after HP1's collapse for this LODRequest
static int VitaLodWedge(USkeletalMesh* mesh, int w, int lod, bool useExtWedges)
{
	if (lod < 0)
		return w;
	const size_t numWedges = useExtWedges ? mesh->ExtWedges.size() : mesh->Wedges.size();
	for (int guard = 0; guard < 1024; guard++)
	{
		if (w < 0 || (size_t)w >= numWedges)
			break;
		const int vertex = useExtWedges ? mesh->ExtWedges[w].Vertex : mesh->Wedges[w].Vertex;
		if (vertex < lod || (size_t)w >= mesh->CollapseWedgeThus.size())
			break;
		const int next = mesh->CollapseWedgeThus[w];
		if (next == w)
			break;
		w = next;
	}
	return w;
}

static bool VitaLodFaceSkipped(USkeletalMesh* mesh, ptrdiff_t face, int lod)
{
	return lod >= 0 && face >= 0 && (size_t)face < mesh->FaceLevel.size() && mesh->FaceLevel[face] > lod;
}
