// Included inside namespace KW at the end of src/knowwonder/Anim/KWSkeletal.cpp by vita/apply_fixes.sh (vita-meshprepass).
//
// Before the actors of a frame are drawn, the skeletal meshes that DrawSkeletalMesh would pose, skin and light are prepared
// together, and the arithmetic runs on the Vita's other cores (VitaJobs.h). Per mesh, in the frame's actor order:
//   main thread: ApplyAnim and the bone coords, the mesh-to-world matrix, SetupMeshLighting (they change shared state: the
//                skeleton caches, aux channels, the light fade cache);
//   any thread:  the skinning (GetFrame's loop), the normals and the vertex light (DrawSkeletalMesh's), into buffers sized before;
//   main thread: the results go into the skin cache (VitaSkinStore), where DrawSkeletalMesh finds them this frame.
// Every mesh gets the same calls in the same order as before, only earlier in the frame; the drawing itself is unchanged.

struct VitaMeshJob
{
	UActor* actor = nullptr;
	USkeletalMesh* mesh = nullptr;
	Array<BoneCoords> bones;
	mat4 meshToWorld;
	MeshLighting lighting;
	bool curvy = false;
	bool fastLight = false;
	int lod = -1;   // VitaLodRequest (VitaMeshLod.inc)
	UActor* animator = nullptr;
	bool animOnWorker = false;   // ApplyAnim and the bone coords run with the rest (else the main thread made them)
	vec3 actorLocation = vec3(0.0f);
	Array<vec3> verts, normals, lights;
	// the main view's opaque faces (VitaMeshFaces.h), when faces is set: what DrawSkeletalMesh's face loop reads
	bool faces = false;
	bool needTranslucent = false;
	float opacity = 1.0f;
	vec3 eye = vec3(0.0f);
	mat3 envRot;
	std::vector<VitaFaceMaterial> mats;
	VitaFaceFloats batch;   // VitaFaceEntry::batch
	std::vector<uint16_t> triMat;
	const VitaSkinEntry* skin = nullptr;   // #189: a faces-only job for a skin cache hit (its arrays are read from the entry)
	std::vector<int> wedgeMap, wedgeVert;
	VitaFaceFloats refBatch;   // faces_check: the old loop's output
	std::vector<uint16_t> refMat;   // per wedge: VitaLodWedge of it and that wedge's vertex (made once by the job)
	uint32_t times[5] = {};   // probes: microseconds of the parts on the worker (pose, skinning, normals, light, faces)
};
static std::vector<VitaMeshJob> VitaMeshJobs;

// VitaSkinLookup's test, without copying anything
static bool VitaSkinWouldHit(UActor* actor, USkeletalMesh* mesh, int lod)
{
	auto it = VitaSkinCache.find(actor);
	if (it == VitaSkinCache.end() || !it->second.valid)
		return false;
	const VitaSkinEntry& e = it->second;
	const vec3 location = actor->Location();
	const Rotator rotation = actor->Rotation();
	if (e.mesh != mesh || !(e.location == location) || e.rotation.Pitch != rotation.Pitch || e.rotation.Yaw != rotation.Yaw ||
		e.rotation.Roll != rotation.Roll || e.scale != actor->DrawScale() || e.lod != lod)
		return false;
	const unsigned age = VitaTimers::frameNumber - e.frame;
	const vec3 d = location - engine->CameraLocation;
	const float distSqr = dot(d, d);
	const unsigned maxAge = distSqr < 700.0f * 700.0f ? 0u : (distSqr < 1500.0f * 1500.0f ? 1u : VitaSkinFarAge());
	return age <= maxAge;
}

// DrawSkeletalMesh's face loop for the opaque pass (its three-core 'buildPart'), on a worker: into job.batch / job.triMat, as
// the device batches them (VitaMeshFaces.h). The same values as the GouraudVertex loop: u, v = (wedge U * width [/ 255]) *
// uMult, the vertex light (times the opacity when below 1), alpha the opacity (1 when not below 1). The fog of the vertices
// is not made: the device never reads it. The LOD wedges come from the maps the normals loop made.
static void VitaMeshJobFaces(VitaMeshJob& job, const Array<vec3>& verts, const Array<vec3>& normals, const Array<vec3>& vertexLights)
{
	USkeletalMesh* mesh = job.mesh;
	const bool useExtWedges = !mesh->ExtWedges.empty();
	const size_t numWedges = useExtWedges ? mesh->ExtWedges.size() : mesh->Wedges.size();
	const int* wedgeMap = job.wedgeMap.data();
	const int* wedgeVert = job.wedgeVert.data();
	const int lod = job.lod;
	const size_t numVerts = verts.size();
	const float opacity = job.opacity;
	const bool faded = opacity < 1.0f;
	const float alpha = faded ? opacity : 1.0f;
	job.batch.resize(mesh->Faces.size() * 27);
	job.triMat.clear();   // (room made on the main thread: a worker must not allocate)
	float* out = job.batch.data();
	for (size_t f = 0; f < mesh->Faces.size(); f++)
	{
		const MeshFace& face = mesh->Faces[f];
		if (VitaLodFaceSkipped(mesh, (ptrdiff_t)f, lod) || face.MaterialIndex >= mesh->Materials.size())
			continue;
		const VitaFaceMaterial& mc = job.mats[face.MaterialIndex];
		if (mc.skip)
			continue;
		const uint32_t renderflags = mc.renderflags;
		const float width = mc.width;
		const float height = mc.height;
		if (face.Indices[0] >= numWedges || face.Indices[1] >= numWedges || face.Indices[2] >= numWedges)
			continue;   // (the original loop found such a face invalid at its first bad corner)
		int v[3];
		bool valid = true;
		for (int i = 0; i < 3; i++)
		{
			v[i] = wedgeVert[face.Indices[i]];
			if (v[i] < 0 || (size_t)v[i] >= numVerts)
				valid = false;
		}
		if (!(renderflags & PF_TwoSided) && valid)
		{
			const vec3 nrm = cross(verts[v[1]] - verts[v[0]], verts[v[2]] - verts[v[0]]);
			if (dot(nrm, job.eye - verts[v[0]]) <= 0.0f)
				continue;
		}
		if (!valid)
			continue;
		for (int i = 0; i < 3; i++, out += 9)
		{
			const int w = wedgeMap[face.Indices[i]];
			const vec3& point = verts[v[i]];
			vec2 uv;
			if (renderflags & PF_Environment)
			{
				vec3 n = normalize(point);
				vec3 pr = job.envRot * reflect(n, normals[v[i]]);
				uv = { (pr.x + 1.0f) * 128.0f * width / 255.0f, (pr.y + 1.0f) * 128.0f * height / 255.0f };
			}
			else if (useExtWedges)
				uv = { mesh->ExtWedges[w].U * width, mesh->ExtWedges[w].V * height };
			else
				uv = { mesh->Wedges[w].U * width / 255.0f, mesh->Wedges[w].V * height / 255.0f };
			vec3 light = (renderflags & PF_Unlit) ? job.lighting.Unlit : vertexLights[v[i]];
			if (faded)
				light *= opacity;
			out[0] = point.x; out[1] = point.y; out[2] = point.z;
			out[3] = uv.x * mc.uMult; out[4] = uv.y * mc.vMult;
			out[5] = light.x; out[6] = light.y; out[7] = light.z;
			out[8] = alpha;
		}
		job.triMat.push_back((uint16_t)face.MaterialIndex);
	}
	job.batch.resize((size_t)(out - job.batch.data()));
}

// every wedge's LOD wedge and vertex once (the face loops asked VitaLodWedge for each corner of each face)
static void VitaMapWedges(VitaMeshJob& job)
{
	USkeletalMesh* mesh = job.mesh;
	const bool useExtWedges = !mesh->ExtWedges.empty();
	const size_t numWedges = useExtWedges ? mesh->ExtWedges.size() : mesh->Wedges.size();
	int* wedgeMap = job.wedgeMap.data();
	int* wedgeVert = job.wedgeVert.data();
	for (size_t w = 0; w < numWedges; w++)
	{
		const int m = VitaLodWedge(mesh, (int)w, job.lod, useExtWedges);
		wedgeMap[w] = m;
		wedgeVert[w] = (m >= 0 && (size_t)m < numWedges) ? (useExtWedges ? mesh->ExtWedges[m].Vertex : mesh->Wedges[m].Vertex) : INT_MAX;
	}
}

// faces_check=1: the old GouraudVertex loop (before #187), its vertices converted as the device did, compared with the new one
static std::atomic<unsigned> VitaFacesChecked{ 0 }, VitaFacesDiffer{ 0 };
static int VitaFacesCheck = -1;   // render.cfg faces_check (read on the main thread)
static void VitaMeshJobFacesRef(VitaMeshJob& job, const Array<vec3>& verts, const Array<vec3>& normals, const Array<vec3>& vertexLights, VitaFaceFloats& batch, std::vector<uint16_t>& triMat)
{
	USkeletalMesh* mesh = job.mesh;
	const bool useExtWedges = !mesh->ExtWedges.empty();
	const size_t numWedges = useExtWedges ? mesh->ExtWedges.size() : mesh->Wedges.size();
	auto wedgeVertex = [&](int w) -> int { return useExtWedges ? mesh->ExtWedges[w].Vertex : mesh->Wedges[w].Vertex; };
	const int lod = job.lod;
	GouraudVertex vertices[3];
	for (size_t f = 0; f < mesh->Faces.size(); f++)
	{
		const MeshFace& face = mesh->Faces[f];
		if (VitaLodFaceSkipped(mesh, (ptrdiff_t)f, lod) || face.MaterialIndex >= mesh->Materials.size())
			continue;
		const VitaFaceMaterial& mc = job.mats[face.MaterialIndex];
		if (mc.skip)
			continue;
		const uint32_t renderflags = mc.renderflags;
		const float width = mc.width;
		const float height = mc.height;
		if (!(renderflags & PF_TwoSided) && face.Indices[0] < numWedges && face.Indices[1] < numWedges && face.Indices[2] < numWedges)
		{
			const int c0 = wedgeVertex(VitaLodWedge(mesh, face.Indices[0], lod, useExtWedges));
			const int c1 = wedgeVertex(VitaLodWedge(mesh, face.Indices[1], lod, useExtWedges));
			const int c2 = wedgeVertex(VitaLodWedge(mesh, face.Indices[2], lod, useExtWedges));
			if (c0 < (int)verts.size() && c1 < (int)verts.size() && c2 < (int)verts.size())
			{
				const vec3 nrm = cross(verts[c1] - verts[c0], verts[c2] - verts[c0]);
				if (dot(nrm, job.eye - verts[c0]) <= 0.0f)
					continue;
			}
		}
		bool valid = true;
		vec3 faceNormals[3];
		int faceVerts[3];
		for (int i = 0; i < 3; i++)
		{
			int w = face.Indices[i];
			if (w >= (int)numWedges) { valid = false; break; }
			w = VitaLodWedge(mesh, w, lod, useExtWedges);
			int v = wedgeVertex(w);
			if (v >= (int)verts.size()) { valid = false; break; }
			vertices[i].Point = verts[v];
			if (useExtWedges)
				vertices[i].UV = { mesh->ExtWedges[w].U * width, mesh->ExtWedges[w].V * height };
			else
				vertices[i].UV = { mesh->Wedges[w].U * width / 255.0f, mesh->Wedges[w].V * height / 255.0f };
			faceNormals[i] = normals[v];
			faceVerts[i] = v;
		}
		if (!valid)
			continue;
		if (renderflags & PF_Environment)
		{
			for (int i = 0; i < 3; i++)
			{
				vec3 v = normalize(vertices[i].Point);
				vec3 pr = job.envRot * reflect(v, faceNormals[i]);
				vertices[i].UV = { (pr.x + 1.0f) * 128.0f * width / 255.0f, (pr.y + 1.0f) * 128.0f * height / 255.0f };
			}
		}
		for (int i = 0; i < 3; i++)
		{
			vertices[i].Light = (renderflags & PF_Unlit) ? job.lighting.Unlit : vertexLights[faceVerts[i]];
			vertices[i].Fog = vec4(0.0f);
		}
		ApplyOpacityVertices(job.opacity, vertices, 3);
		for (const GouraudVertex& p : vertices)
		{
			const float vertex[9] = { p.Point.x, p.Point.y, p.Point.z, p.UV.x * mc.uMult, p.UV.y * mc.vMult, p.Light.x, p.Light.y, p.Light.z, p.Alpha };
			batch.insert(batch.end(), vertex, vertex + 9);
		}
		triMat.push_back((uint16_t)face.MaterialIndex);
	}
}

static void VitaMeshJobRun(void* context, int index)
{
	VitaMeshJob& job = ((VitaMeshJob*)context)[index];
	USkeletalMesh* mesh = job.mesh;
	const bool timed = VitaProbes::enabled;
	uint64_t mark = timed ? VitaProbes::Now() : 0;
	auto lap = [&](int part) { if (timed) { const uint64_t now = VitaProbes::Now(); job.times[part] = (uint32_t)(now - mark); mark = now; } };
	if (job.skin)
	{
		// #189: the kept skinning of a skin cache hit; only its faces are made
		VitaMapWedges(job);
		VitaMeshJobFaces(job, job.skin->verts, job.skin->normals, job.skin->lights);
		lap(4);
		return;
	}
	if (job.animOnWorker)
	{
		// The animator's skeleton cache exists and its animation is loaded (the main thread saw to it): ApplyAnim only reads the
		// actor and the animation and writes that cache; it has no aux channel (which may destroy actors)
		ApplyAnim(mesh, job.animator, nullptr);
		ComputeBones(job.animator, mesh, job.bones);
	}
	lap(0);
	const Array<BoneCoords>& bones = job.bones;
	Array<vec3>& outVerts = job.verts;   // sized and zeroed by the main thread
	const size_t numBones = mesh->RefSkeleton.size();
	const size_t numVerts = outVerts.size();

	// GetFrame's skinning
	if (mesh->BoneWeightIndices.size() == 1)
	{
		size_t count = std::min<size_t>(mesh->BoneWeightIndices[0].Number, std::min(numVerts, mesh->LocalPoints.size()));
		for (size_t k = 0; k < count; k++)
			outVerts[k] = bones[0].Apply(mesh->LocalPoints[k]);
	}
	else
	{
		for (size_t n = 0; n < mesh->BoneWeightIndices.size() && n < numBones; n++)
		{
			const BoneWeightIndex& weightIndex = mesh->BoneWeightIndices[n];
			for (size_t k = weightIndex.WeightIndex; k < (size_t)weightIndex.WeightIndex + weightIndex.Number; k++)
			{
				if (k >= mesh->BoneWeights.size() || k >= mesh->LocalPoints.size())
					break;
				uint32_t point = mesh->BoneWeights[k].PointIndex;
				if (point >= numVerts)
					break;
				float weight = mesh->BoneWeights[k].BoneWeight * (1.0f / 65535.0f);
				outVerts[point] += bones[n].Apply(mesh->LocalPoints[k]) * weight;
			}
		}
	}
	for (vec3& v : outVerts)
		v = (job.meshToWorld * vec4(v, 1.0f)).xyz();
	lap(1);

	// DrawSkeletalMesh's smooth normals
	Array<vec3>& normals = job.normals;   // sized and zeroed by the main thread
	const bool useExtWedges = !mesh->ExtWedges.empty();
	const size_t numWedges = useExtWedges ? mesh->ExtWedges.size() : mesh->Wedges.size();
	auto wedgeVertex = [&](int w) -> int { return useExtWedges ? mesh->ExtWedges[w].Vertex : mesh->Wedges[w].Vertex; };
	const int lod = job.lod;
	VitaMapWedges(job);
	const int* wedgeVert = job.wedgeVert.data();
	for (const MeshFace& face : mesh->Faces)
	{
		if (face.Indices[0] >= numWedges || face.Indices[1] >= numWedges || face.Indices[2] >= numWedges)
			continue;
		if (VitaLodFaceSkipped(mesh, &face - mesh->Faces.data(), lod))
			continue;
		int i0 = wedgeVert[face.Indices[0]];
		int i1 = wedgeVert[face.Indices[1]];
		int i2 = wedgeVert[face.Indices[2]];
		if (i0 >= (int)outVerts.size() || i1 >= (int)outVerts.size() || i2 >= (int)outVerts.size())
			continue;
		vec3 n = cross(outVerts[i1] - outVerts[i0], outVerts[i2] - outVerts[i0]);
		normals[i0] += n;
		normals[i1] += n;
		normals[i2] += n;
	}
	if (job.curvy)
	{
		for (size_t i = 0; i < outVerts.size(); i++)
			normals[i] = outVerts[i] - job.actorLocation;
	}
	for (vec3& n : normals)
		n *= 1.0f / std::sqrt(dot(n, n) + 0.001f);
	lap(2);

	// and the vertex light
	if (job.fastLight && normals.size() >= outVerts.size())
		VitaLightVertices(job.lighting, outVerts.data(), normals.data(), job.lights.data(), outVerts.size());
	else
		for (size_t i = 0; i < outVerts.size(); i++)
			job.lights[i] = job.lighting.Light(outVerts[i], normals[i]);

	lap(3);
	if (job.faces)
	{
		VitaMeshJobFaces(job, job.verts, job.normals, job.lights);
		if (VitaFacesCheck > 0)
		{
			VitaFaceFloats& refBatch = job.refBatch;
			std::vector<uint16_t>& refMat = job.refMat;
			VitaMeshJobFacesRef(job, job.verts, job.normals, job.lights, refBatch, refMat);
			VitaFacesChecked++;
			if (refBatch.size() != job.batch.size() || refMat != job.triMat || memcmp(refBatch.data(), job.batch.data(), refBatch.size() * sizeof(float)) != 0)
				VitaFacesDiffer++;
		}
	}
	lap(4);
}

// The main view starts its prepass before its level surfaces are drawn (VitaPrepareMeshesBegin, from VisibleFrame::Draw
// after DrawPortals: the sky/mirror frames draw the same actors, so not before them); the workers skin while the main thread
// draws the surfaces, and VitaPrepareMeshes (DrawOpaqueActors) joins in and stores the results. render.cfg prepass_early=0:
// all of it in DrawOpaqueActors as before.
static VisibleFrame* VitaPrepassFrame = nullptr;   // the frame whose jobs run asynchronously
static size_t VitaPrepassCount = 0;

static size_t VitaPrepareMeshJobs(VisibleFrame* frame, bool stream = false);

// VitaSkinStore, the arrays handed over instead of copied (the job's buffers are sized again next frame)
static void VitaSkinStoreSwap(UActor* actor, USkeletalMesh* mesh, Array<vec3>& verts, Array<vec3>& normals, Array<vec3>& lights, const vec3& unlit, int lod)
{
	if (!VitaSkinCacheOn())
		return;
	VITA_LEVEL_EPOCH_CLEAR(VitaSkinCache);
	if (VitaSkinCache.size() > 600)
		VitaSkinCache.clear();   // actors that are gone leave their entries behind
	VitaSkinEntry& e = VitaSkinCache[actor];
	e.frame = VitaTimers::frameNumber;
	e.mesh = mesh;
	e.location = actor->Location();
	e.rotation = actor->Rotation();
	e.scale = actor->DrawScale();
	e.unlit = unlit;
	e.verts.swap(verts);
	e.normals.swap(normals);
	e.lights.swap(lights);
	e.valid = true;
	e.lod = lod;
}

static const VisibleFrame* VitaPreparedFrame = nullptr;   // the frame the jobs were set up for (their faces' eye)

static void VitaStorePreparedMeshes(size_t count)
{
	if (VitaFacesCheck > 0 && VitaFacesChecked.load() >= 500)
	{
		LogMessage("VitaFacesCheck: " + std::to_string(VitaFacesChecked.load()) + " meshes, " + std::to_string(VitaFacesDiffer.load()) + " differ");
		VitaFacesChecked = 0;
		VitaFacesDiffer = 0;
	}
	VITA_LEVEL_EPOCH_CLEAR(VitaFaceCache);
	if (VitaFaceCache.size() > 600)
		VitaFaceCache.clear();   // actors that are gone leave their entries behind
	for (size_t i = 0; i < count; i++)
	{
		VitaMeshJob& job = VitaMeshJobs[i];
		if (VitaProbes::enabled)
			for (int part = 0; part < 5; part++)
			{
				VitaProbes::us[VitaProbes::JobAnim + part] += job.times[part];
				VitaProbes::calls[VitaProbes::JobAnim + part]++;
				job.times[part] = 0;
			}
		if (!job.skin)
			VitaSkinStoreSwap(job.actor, job.mesh, job.verts, job.normals, job.lights, job.lighting.Unlit, job.lod);
		if (job.faces)
		{
			VitaFaceEntry& e = VitaFaceCache[job.actor];
			e.frame = VitaPreparedFrame;
			e.stamp = VitaTimers::frameNumber;
			e.mesh = job.mesh;
			e.lod = job.lod;
			e.needTranslucent = job.needTranslucent;
			e.batch.swap(job.batch);
			e.triMat.swap(job.triMat);
			e.mats.swap(job.mats);
		}
	}
}

void VitaPrepareMeshesBegin(VisibleFrame* frame)
{
	static const bool early = VitaConfigInt("prepass_early", 1) != 0;
	VitaPrepassFrame = nullptr;
	if (!early || VitaJobs::Mode() < 2 || !VitaSkinCacheOn())
		return;
	VITA_PROBE(MeshPrepass);
	VitaPreparedFrame = frame;
	size_t count;
	static const bool stream = VitaConfigInt("prepass_stream", 1) != 0;
	if (stream)
	{
		// #186: the workers start on each job as soon as it is set up (VitaPrepareMeshJobs publishes them)
		{ VITA_PROBE(PrepassSetup); count = VitaPrepareMeshJobs(frame, true); }
		if (count != (size_t)-1)
		{
			VitaPrepassFrame = frame;
			VitaPrepassCount = count;
			return;
		}
		count = VitaPrepareMeshJobs(frame);   // the workers did not start
	}
	else
	{ VITA_PROBE(PrepassSetup); count = VitaPrepareMeshJobs(frame); }
	if (VitaJobs::BeginAsync(VitaMeshJobRun, VitaMeshJobs.data(), (int)count))
	{
		VitaPrepassFrame = frame;
		VitaPrepassCount = count;
		return;
	}
	VitaJobs::Run(VitaMeshJobRun, VitaMeshJobs.data(), (int)count);
	VitaStorePreparedMeshes(count);
	VitaPrepassFrame = frame;   // done: nothing left for VitaPrepareMeshes
	VitaPrepassCount = 0;
}

void VitaPrepareMeshes(VisibleFrame* frame)
{
	if (VitaJobs::Mode() <= 0 || !VitaSkinCacheOn())
		return;
	VITA_PROBE(MeshPrepass);
	if (frame == VitaPrepassFrame)
	{
		{ VITA_PROBE(PrepassJoin); VitaJobs::FinishAsync(); }
		{ VITA_PROBE(PrepassStore); VitaStorePreparedMeshes(VitaPrepassCount); }
		VitaPrepassFrame = nullptr;
		VitaPrepassCount = 0;
		return;
	}
	VitaPreparedFrame = frame;
	const size_t count = VitaPrepareMeshJobs(frame);
	VitaJobs::Run(VitaMeshJobRun, VitaMeshJobs.data(), (int)count);
	VitaStorePreparedMeshes(count);
}

// The jobs of a frame's meshes, set up on the main thread (returns how many). In two passes: first what may insert into
// the skeleton caches (LOD, the skin cache test, the pose or its preparations), then the rest of each job. stream (#186): a
// streamed run starts before the second pass and each job is published as soon as it is ready (the workers only read their
// job, the mesh and their animator's cache entry, which the second pass leaves alone); returns -1 when the workers could
// not start (nothing set up).
static size_t VitaPrepareMeshJobs(VisibleFrame* frame, bool stream)
{
	if (VitaFacesCheck < 0)
		VitaFacesCheck = VitaConfigInt("faces_check", 0);
	if (stream)
	{
		if (VitaMeshJobs.size() < frame->Actors.size())
			VitaMeshJobs.resize(frame->Actors.size());   // the jobs must not move once the workers have them
	}

	// Animators shared by more than one mesh of the frame are posed on the main thread, in order (anim_threads=0: all of them)
	static const bool animThreads = VitaConfigInt("anim_threads", 1) != 0;
	static std::unordered_map<UActor*, int> animatorUses;
	animatorUses.clear();
	for (VisibleActor& visible : frame->Actors)
	{
		if (visible.Type == DT_Mesh && visible.Actor->Mesh())
		{
			UActor* a = visible.Actor;
			animatorUses[(a->bAnimByOwner() && a->Owner()) ? a->Owner() : a]++;
		}
	}

	size_t count = 0;
	for (VisibleActor& visible : frame->Actors)
	{
		if (visible.Type != DT_Mesh)
			continue;
		UActor* actor = visible.Actor;
		USkeletalMesh* mesh = UObject::TryCast<USkeletalMesh>(actor->Mesh());
		if (!mesh || mesh->RefSkeleton.empty() || mesh->BoneWeightIndices.empty())
			continue;
		if (VitaMeshDistance() > 0.0f)   // VisibleMesh::DrawMesh does not draw it
		{
			vec3 toActor = actor->Location() - engine->CameraLocation;
			if (dot(toActor, toActor) > VitaMeshDistance() * VitaMeshDistance())
				continue;
		}
		VITA_LAP_START;
		const int lod = VitaLodRequest(frame, actor, mesh);
		const bool skinHit = VitaSkinWouldHit(actor, mesh, lod);   // DrawSkeletalMesh will use what is kept
		if (skinHit && !(VitaFacesOn() && frame->PortalDepth == 0))
			continue;

		if (VitaMeshJobs.size() <= count)
			VitaMeshJobs.resize(count + 1);
		VitaMeshJob& job = VitaMeshJobs[count++];
		job.actor = actor;
		job.mesh = mesh;
		job.lod = lod;
		job.skin = skinHit ? &VitaSkinCache.find(actor)->second : nullptr;   // #189: only its faces, from the kept arrays
		VITA_LAP(SetupLod);
		if (skinHit)
			continue;

		// GetFrame up to the skinning: on this thread, or (anim_threads) on the workers after the shared state is ready here
		UActor* animator = actor;
		if (actor->bAnimByOwner() && actor->Owner())
			animator = actor->Owner();
		job.animator = animator;
		job.animOnWorker = animThreads && VitaJobs::Mode() >= 2 && animatorUses[animator] == 1 && AuxAnims(animator).size() == 0;
		if (job.animOnWorker)
		{
			GetSkelCache(animator, mesh);   // the cache entry (an insertion into SkelCaches)
			if (UAnimation* anim = animator->SkelAnim())
				GetAnimationData(anim);   // LoadNow: may read the package
			if (mesh->DefaultAnimation)
				GetAnimationData(mesh->DefaultAnimation);
			job.bones.resize(mesh->RefSkeleton.size());
		}
		else
		{
			ApplyAnim(mesh, animator, nullptr);
			ComputeBones(animator, mesh, job.bones);
		}
		VITA_LAP(SetupAnim);
	}

	if (stream && !VitaJobs::BeginStream(VitaMeshJobRun, VitaMeshJobs.data()))
		return (size_t)-1;
	for (size_t jobIndex = 0; jobIndex < count; jobIndex++)
	{
		VITA_LAP_START;
		VitaMeshJob& job = VitaMeshJobs[jobIndex];
		UActor* actor = job.actor;
		USkeletalMesh* mesh = job.mesh;
		job.meshToWorld = GetMeshToWorld(actor, mesh);

		// DrawSkeletalMesh's lighting setup
		UZoneInfo* zoneActor = engine->GetZoneActor(actor->Region().ZoneNumber);
		job.lighting = MeshLighting();
		if (job.skin)
			job.lighting.Unlit = job.skin->unlit;   // as DrawSkeletalMesh's skin hit (no SetupMeshLighting)
		else
			SetupMeshLighting(job.lighting, actor, actor, zoneActor);
		job.curvy = actor->bMeshCurvy();
		job.actorLocation = actor->Location();
		job.fastLight = VitaMeshFast();

		// The faces (VitaMeshFaces.h): the main view's opaque pass, what DrawSkeletalMesh works out before its face loop
		VITA_LAP(SetupLight);
		job.faces = VitaFacesOn() && frame->PortalDepth == 0;
		if (job.faces)
		{
			uint32_t polyFlags = 0;
			switch (actor->Style())
			{
			default: break;
			case STY_Masked: polyFlags |= PF_Masked; break;
			case STY_Translucent: polyFlags |= PF_Translucent; break;
			case STY_Modulated: polyFlags |= PF_Modulated; break;
			}
			if (actor->bNoSmooth()) polyFlags |= PF_NoSmooth;
			if (actor->bSelected()) polyFlags |= PF_Selected;
			if (actor->bMeshEnviroMap()) polyFlags |= PF_Environment;
			if (actor->bMeshCurvy()) polyFlags |= PF_Flat;
			if (actor->bUnlit()) polyFlags |= PF_Unlit;
			job.opacity = MeshOpacity(actor);
			job.eye = frame->EyeLocation();
			job.envRot = mat3(frame->Frame.WorldToView * frame->Frame.ObjectToWorld);
			VisibleMesh::VitaSetupLodMeshTextures(actor, mesh);
			// the materials where the face loop would meet them first (only those of faces it draws): their order is the same
			// for a mesh at a LOD, kept
			static std::unordered_map<uint64_t, std::vector<uint16_t>> materialOrders;
			VITA_LEVEL_EPOCH_CLEAR(materialOrders);
			std::vector<uint16_t>& order = materialOrders[((uint64_t)(uintptr_t)mesh << 16) ^ (uint64_t)(uint16_t)(job.lod + 1)];
			if (order.empty())
			{
				std::vector<char> seen(mesh->Materials.size(), 0);
				for (size_t f = 0; f < mesh->Faces.size(); f++)
				{
					const MeshFace& face = mesh->Faces[f];
					if (VitaLodFaceSkipped(mesh, (ptrdiff_t)f, job.lod) || face.MaterialIndex >= mesh->Materials.size() || seen[face.MaterialIndex])
						continue;
					seen[face.MaterialIndex] = 1;
					order.push_back((uint16_t)face.MaterialIndex);
				}
				if (order.empty())
					order.push_back(0xffff);   // no material drawn
			}
			job.mats.assign(mesh->Materials.size(), VitaFaceMaterial());
			job.needTranslucent = false;
			for (uint16_t materialIndex : order)
			{
				if (materialIndex == 0xffff)
					continue;
				VitaFaceMaterial& mc = job.mats[materialIndex];
				mc.ready = true;
				mc.skip = true;
				const MeshMaterial& material = mesh->Materials[materialIndex];
				if (material.PolyFlags & PF_Invisible)
					continue;
				uint32_t renderflags = material.PolyFlags | polyFlags;
				ApplyOpacityFlags(job.opacity, renderflags);
				UTexture* tex = (renderflags & PF_Environment) ? engine->render->Mesh.envmap : (material.TextureIndex < engine->render->Mesh.textures.size() ? engine->render->Mesh.textures[material.TextureIndex] : nullptr);
				if (!tex)
					continue;
				if ((renderflags & (PF_Translucent | PF_Modulated | PF_Highlighted)) != 0)
				{
					job.needTranslucent = true;
					continue;
				}
				engine->render->UpdateTexture(tex);
				engine->render->UpdateTextureInfo(mc.texinfo, tex);
				mc.renderflags = renderflags;
				mc.width = mc.texinfo.Texture ? (float)mc.texinfo.Texture->UsedMipmaps.front().Width : 256.0f;
				mc.height = mc.texinfo.Texture ? (float)mc.texinfo.Texture->UsedMipmaps.front().Height : 256.0f;
				mc.uMult = GetUMult(mc.texinfo);
				mc.vMult = GetVMult(mc.texinfo);
				mc.skip = false;
			}
		}

		VITA_LAP(SetupFaces);
		const size_t numVerts = mesh->Points.size();
		if (!job.skin)
		{
			job.verts.clear();
			job.verts.resize(numVerts, vec3(0.0f));
			job.normals.clear();
			job.normals.resize(numVerts, vec3(0.0f));
			job.lights.resize(numVerts);
		}
		const size_t numWedges = mesh->ExtWedges.empty() ? mesh->Wedges.size() : mesh->ExtWedges.size();
		job.wedgeMap.resize(numWedges);
		job.wedgeVert.resize(numWedges);
		if (job.faces)
		{
			job.batch.reserve(mesh->Faces.size() * 27);
			job.triMat.reserve(mesh->Faces.size());
			if (VitaFacesCheck > 0)
			{
				job.refBatch.clear();
				job.refBatch.reserve(mesh->Faces.size() * 27);
				job.refMat.clear();
				job.refMat.reserve(mesh->Faces.size());
			}
		}
		VITA_LAP(SetupBuffers);
		if (stream)
			VitaJobs::Publish((int)jobIndex + 1);
	}

	return count;
}
