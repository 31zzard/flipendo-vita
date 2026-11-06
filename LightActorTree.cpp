
#include "Precomp.h"
#include "LightActorTree.h"
#include "Packages/Engine/Actors/UActor.h"
#include <cstring>

void LightActorTree::CollectLights(const vec3& center, float radius)
{
	CollectedLights.clear();
	if (TLAS.Root != -1)
		CollectLights(center, radius, TLAS.Root);
}

void LightActorTree::CollectLights(const vec3& center, float radius, int nodeIndex)
{
	const Node& node = TLAS.Nodes[nodeIndex];
	if (node.blas_index != -1)
	{
		CollectedLights.push_back(Lights[node.blas_index]);
	}
	if (node.left != -1)
	{
		OverlapResult result = TestSphereAABB(center, radius, TLAS.Nodes[node.left].aabb.min, TLAS.Nodes[node.left].aabb.max);
		if (result == OverlapResult::overlap)
			CollectLights(center, radius, node.left);
	}
	if (node.right != -1)
	{
		OverlapResult result = TestSphereAABB(center, radius, TLAS.Nodes[node.right].aabb.min, TLAS.Nodes[node.right].aabb.max);
		if (result == OverlapResult::overlap)
			CollectLights(center, radius, node.right);
	}
}

template<typename T>
static bool SameData(const std::vector<T>& a, const std::vector<T>& b)
{
	return a.size() == b.size() && (a.empty() || std::memcmp(a.data(), b.data(), a.size() * sizeof(T)) == 0);
}

void LightActorTree::CreateTLAS()
{
	// vita-lighttree: Location() and WorldLightRadius() are script property reads, and the original read them again for
	// every light on every level of the tree, every frame. Read them once...
	const int lightCount = (int)Lights.size();
	Scratch.locs.clear();
	Scratch.radii.clear();
	Scratch.locs.reserve(lightCount);
	Scratch.radii.reserve(lightCount);
	for (int i = 0; i < lightCount; i++)
	{
		Scratch.locs.push_back(Lights[i]->Location());
		Scratch.radii.push_back(Lights[i]->WorldLightRadius());
	}

	// ...and keep the tree when nothing it was built from changed (most lights never move)
	if (TLAS.Root != -1 && Previous.lights == Lights && SameData(Previous.locs, Scratch.locs) && SameData(Previous.radii, Scratch.radii))
		return;
	Previous.lights = Lights;
	Previous.locs = Scratch.locs;
	Previous.radii = Scratch.radii;

	Scratch.leafs.clear();
	Scratch.leafs.reserve(Lights.size());
	Scratch.centroids.clear();
	Scratch.centroids.reserve(Lights.size());
	for (int i = 0; i < Lights.size(); i++)
	{
		Scratch.leafs.push_back(i);
		Scratch.centroids.push_back(vec4(Scratch.locs[i], 1.0f));
	}

	size_t neededbuffersize = Lights.size() * 2;
	if (Scratch.workbuffer.size() < neededbuffersize)
		Scratch.workbuffer.resize(neededbuffersize);

	TLAS.Nodes.clear();
	TLAS.Root = Subdivide(Scratch.leafs.data(), (int)Scratch.leafs.size(), Scratch.centroids.data(), Scratch.workbuffer.data());
}

int LightActorTree::Subdivide(int* instances, int numInstances, const vec4* centroids, int* workBuffer)
{
	if (numInstances == 0)
		return -1;

	// Find bounding box and median of the instance centroids
	vec3 median(0.0f, 0.0f, 0.0f);
	vec3 min = Scratch.locs[instances[0]] - Scratch.radii[instances[0]];
	vec3 max = Scratch.locs[instances[0]] + Scratch.radii[instances[0]];
	for (int i = 0; i < numInstances; i++)
	{
		vec3 location = Scratch.locs[instances[i]];
		float radius = Scratch.radii[instances[i]];

		min.x = std::min(min.x, location.x - radius);
		min.y = std::min(min.y, location.y - radius);
		min.z = std::min(min.z, location.z - radius);

		max.x = std::max(max.x, location.x + radius);
		max.y = std::max(max.y, location.y + radius);
		max.z = std::max(max.z, location.z + radius);

		median += centroids[instances[i]].xyz();
	}
	median /= (float)numInstances;

	// For numerical stability
	min.x -= 0.1f;
	min.y -= 0.1f;
	min.z -= 0.1f;
	max.x += 0.1f;
	max.y += 0.1f;
	max.z += 0.1f;

	if (numInstances == 1) // Leaf node
	{
		TLAS.Nodes.push_back(Node(min, max, instances[0]));
		return (int)TLAS.Nodes.size() - 1;
	}

	// Find the longest axis
	float axis_lengths[3] =
	{
		max.x - min.x,
		max.y - min.y,
		max.z - min.z
	};

	int axis_order[3] = { 0, 1, 2 };
	std::sort(axis_order, axis_order + 3, [&](int a, int b) { return axis_lengths[a] > axis_lengths[b]; });

	// Try split at longest axis, then if that fails the next longest, and then the remaining one
	int left_count, right_count;
	vec3 axis;
	for (int attempt = 0; attempt < 3; attempt++)
	{
		// Find the split plane for axis
		switch (axis_order[attempt])
		{
		default:
		case 0: axis = vec3(1.0f, 0.0f, 0.0f); break;
		case 1: axis = vec3(0.0f, 1.0f, 0.0f); break;
		case 2: axis = vec3(0.0f, 0.0f, 1.0f); break;
		}
		vec4 plane(axis, -dot(median, axis));

		// Split instances into two
		left_count = 0;
		right_count = 0;
		for (int i = 0; i < numInstances; i++)
		{
			int instance = instances[i];

			float side = dot(centroids[instance], plane);
			if (side >= 0.0f)
			{
				workBuffer[left_count] = instance;
				left_count++;
			}
			else
			{
				workBuffer[numInstances + right_count] = instance;
				right_count++;
			}
		}

		if (left_count != 0 && right_count != 0)
			break;
	}

	// Check if something went wrong when splitting and do a random split instead
	if (left_count == 0 || right_count == 0)
	{
		left_count = numInstances / 2;
		right_count = numInstances - left_count;
	}
	else
	{
		// Move result back into instances list:
		for (int i = 0; i < left_count; i++)
			instances[i] = workBuffer[i];
		for (int i = 0; i < right_count; i++)
			instances[i + left_count] = workBuffer[numInstances + i];
	}

	// Create child nodes:
	int left_index = -1;
	int right_index = -1;
	if (left_count > 0)
		left_index = Subdivide(instances, left_count, centroids, workBuffer);
	if (right_count > 0)
		right_index = Subdivide(instances + left_count, right_count, centroids, workBuffer);

	TLAS.Nodes.push_back(Node(min, max, left_index, right_index));
	return (int)TLAS.Nodes.size() - 1;
}

LightActorTree::OverlapResult LightActorTree::TestSphereAABB(const vec3& center, float radius, const vec3& aabb_min, const vec3& aabb_max)
{
	vec3 a = aabb_min - center;
	vec3 b = center - aabb_max;
	a.x = std::max(a.x, 0.0f);
	a.y = std::max(a.y, 0.0f);
	a.z = std::max(a.z, 0.0f);
	b.x = std::max(b.x, 0.0f);
	b.y = std::max(b.y, 0.0f);
	b.z = std::max(b.z, 0.0f);
	vec3 e = a + b;
	float d = dot(e, e);
	if (d > radius * radius)
		return OverlapResult::disjoint;
	else
		return OverlapResult::overlap;
}
