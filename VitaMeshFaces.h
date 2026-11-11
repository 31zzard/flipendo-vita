// Mesh faces made by the mesh prepass (apply_fixes.sh #174; included inside namespace KW in src/knowwonder/Anim/KWSkeletal.cpp).
//
// DrawSkeletalMesh's face loop (the triangles of every visible face: wedge UVs, the vertex light, the fog, the opacity) was ~270 us
// a mesh on the main thread (Lev2_Inc_A's greenhouse: 19 meshes, ~5 ms a frame), and its three-core version per mesh gained nothing:
// a part is done before the woken workers start on it. The mesh prepass (VitaMeshPrepass.inc) now makes the main view's opaque
// faces of every mesh it skins on the workers, while the main thread draws the level surfaces; DrawSkeletalMesh only hands the runs
// over. The same faces in the same order, in runs of one material as before. Not for the translucent pass, mirrors/sky frames,
// weapons (another light actor), or a skin cache hit (no prepass job): those draw as before. render.cfg prepass_faces=0: off.

// resize() leaves the new floats unset (the job writes every one it keeps): as VitaRenderDevice.h's VitaNoInitAlloc
template <class T> struct VitaFacesNoInit : std::allocator<T>
{
	template <class U> struct rebind { using other = VitaFacesNoInit<U>; };
	VitaFacesNoInit() = default;
	template <class U> VitaFacesNoInit(const VitaFacesNoInit<U>&) {}
	template <class U> void construct(U* p) noexcept { ::new ((void*)p) U; }
	template <class U, class... A> void construct(U* p, A&&... a) { ::new ((void*)p) U(std::forward<A>(a)...); }
};
typedef std::vector<float, VitaFacesNoInit<float>> VitaFaceFloats;

struct VitaFaceMaterial
{
	TextureInfo texinfo;
	uint32_t renderflags = 0;
	float width = 256.0f;
	float height = 256.0f;
	float uMult = 1.0f, vMult = 1.0f;   // GetUMult / GetVMult of texinfo: the device's texture coordinates are made on the worker
	bool ready = false;
	bool skip = true;
};

struct VitaFaceEntry
{
	const VisibleFrame* frame = nullptr;
	unsigned stamp = ~0u;   // VitaTimers::frameNumber it was made for (~0: used)
	USkeletalMesh* mesh = nullptr;
	int lod = -1;
	bool needTranslucent = false;
	VitaFaceFloats batch;   // the triangles' vertices as the device batches them (x y z, u v scaled, r g b unscaled, a: 9 floats)
	std::vector<uint16_t> triMat;
	std::vector<VitaFaceMaterial> mats;
};
static std::unordered_map<UActor*, VitaFaceEntry> VitaFaceCache;

static bool VitaFacesOn()
{
	static const bool on = VitaConfigInt("prepass_faces", 1) != 0;
	return on;
}

// true: the opaque faces of this draw were made by the prepass and are drawn here (needTranslucent: what the face loop says)
static bool VitaDrawPreparedFaces(VisibleFrame* frame, UActor* actor, USkeletalMesh* mesh, int lod, bool& needTranslucent)
{
	auto it = VitaFaceCache.find(actor);
	if (it == VitaFaceCache.end())
		return false;
	VitaFaceEntry& e = it->second;
	if (e.frame != frame || e.stamp != VitaTimers::frameNumber || e.mesh != mesh || e.lod != lod)
		return false;
	e.stamp = ~0u;
	const size_t total = e.triMat.size();
	size_t runStart = 0;
	for (size_t t = 1; t <= total; t++)
	{
		if (t < total && e.triMat[t] == e.triMat[runStart])
			continue;
		VitaFaceMaterial& mc = e.mats[e.triMat[runStart]];
		VITA_PROBE(MeshDevice);
		// what DrawGouraudTriangles would write: u, v times the texture's multipliers (done on the worker), the light times the
		// exposure, colours 1 when modulated (never here: modulated materials go to the translucent pass)
		const int numVerts = (int)(t - runStart) * 3;
		float params[4];
		float* out = frame->Device->VitaBeginTriangles(&frame->Frame, mc.texinfo, mc.renderflags | PF_RenderFog, numVerts, params);
		if (out)
		{
			const float* in = e.batch.data() + runStart * 27;
			if (params[0] == mc.uMult && params[1] == mc.vMult && params[2] == 1.0f && params[3] == 0.0f)
				memcpy(out, in, (size_t)numVerts * 9 * sizeof(float));
			else
			{
				for (int i = 0; i < numVerts; i++, in += 9, out += 9)
				{
					out[0] = in[0]; out[1] = in[1]; out[2] = in[2];
					out[3] = params[0] == mc.uMult ? in[3] : in[3] / mc.uMult * params[0];
					out[4] = params[1] == mc.vMult ? in[4] : in[4] / mc.vMult * params[1];
					out[5] = params[3] != 0.0f ? 1.0f : in[5] * params[2];
					out[6] = params[3] != 0.0f ? 1.0f : in[6] * params[2];
					out[7] = params[3] != 0.0f ? 1.0f : in[7] * params[2];
					out[8] = in[8];
				}
			}
			frame->Device->VitaEndTriangles(numVerts);
		}
		runStart = t;
	}
	needTranslucent = e.needTranslucent;
	return true;
}
