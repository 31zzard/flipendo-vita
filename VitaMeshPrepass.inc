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

static void VitaMeshJobRun(void* context, int index)
{
	VitaMeshJob& job = ((VitaMeshJob*)context)[index];
	USkeletalMesh* mesh = job.mesh;
	if (job.animOnWorker)
	{
		// The animator's skeleton cache exists and its animation is loaded (the main thread saw to it): ApplyAnim only reads the
		// actor and the animation and writes that cache; it has no aux channel (which may destroy actors)
		ApplyAnim(mesh, job.animator, nullptr);
		ComputeBones(job.animator, mesh, job.bones);
	}
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

	// DrawSkeletalMesh's smooth normals
	Array<vec3>& normals = job.normals;   // sized and zeroed by the main thread
	const bool useExtWedges = !mesh->ExtWedges.empty();
	const size_t numWedges = useExtWedges ? mesh->ExtWedges.size() : mesh->Wedges.size();
	auto wedgeVertex = [&](int w) -> int { return useExtWedges ? mesh->ExtWedges[w].Vertex : mesh->Wedges[w].Vertex; };
	const int lod = job.lod;
	for (const MeshFace& face : mesh->Faces)
	{
		if (face.Indices[0] >= numWedges || face.Indices[1] >= numWedges || face.Indices[2] >= numWedges)
			continue;
		if (VitaLodFaceSkipped(mesh, &face - mesh->Faces.data(), lod))
			continue;
		int i0 = wedgeVertex(VitaLodWedge(mesh, face.Indices[0], lod, useExtWedges));
		int i1 = wedgeVertex(VitaLodWedge(mesh, face.Indices[1], lod, useExtWedges));
		int i2 = wedgeVertex(VitaLodWedge(mesh, face.Indices[2], lod, useExtWedges));
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

	// and the vertex light
	if (job.fastLight && normals.size() >= outVerts.size())
		VitaLightVertices(job.lighting, outVerts.data(), normals.data(), job.lights.data(), outVerts.size());
	else
		for (size_t i = 0; i < outVerts.size(); i++)
			job.lights[i] = job.lighting.Light(outVerts[i], normals[i]);
}

void VitaPrepareMeshes(VisibleFrame* frame)
{
	if (VitaJobs::Mode() <= 0 || !VitaSkinCacheOn())
		return;
	VITA_PROBE(MeshPrepass);

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
		const int lod = VitaLodRequest(frame, actor, mesh);
		if (VitaSkinWouldHit(actor, mesh, lod))   // DrawSkeletalMesh will use what is kept
			continue;

		if (VitaMeshJobs.size() <= count)
			VitaMeshJobs.resize(count + 1);
		VitaMeshJob& job = VitaMeshJobs[count++];
		job.actor = actor;
		job.mesh = mesh;
		job.lod = lod;

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
		job.meshToWorld = GetMeshToWorld(actor, mesh);

		// DrawSkeletalMesh's lighting setup
		UZoneInfo* zoneActor = engine->GetZoneActor(actor->Region().ZoneNumber);
		job.lighting = MeshLighting();
		SetupMeshLighting(job.lighting, actor, actor, zoneActor);
		job.curvy = actor->bMeshCurvy();
		job.actorLocation = actor->Location();
		job.fastLight = VitaMeshFast();

		const size_t numVerts = mesh->Points.size();
		job.verts.clear();
		job.verts.resize(numVerts, vec3(0.0f));
		job.normals.clear();
		job.normals.resize(numVerts, vec3(0.0f));
		job.lights.resize(numVerts);
	}

	VitaJobs::Run(VitaMeshJobRun, VitaMeshJobs.data(), (int)count);

	for (size_t i = 0; i < count; i++)
	{
		VitaMeshJob& job = VitaMeshJobs[i];
		VitaSkinStore(job.actor, job.mesh, job.verts, job.normals, job.lights, job.lighting.Unlit, job.lod);
	}
}
