#define DISABLE_SOFT_SHADOWMAP
#define DISABLE_VOXELGI
#include "objectHF.hlsli"
#include "voxelHF.hlsli"
#include "volumetricCloudsHF.hlsli"
#include "cullingShaderHF.hlsli"

// Note: the voxelizer uses an overall simplified material and lighting model (no normal maps, only diffuse light and emissive)

Texture3D<float4> input_previous_radiance : register(t0);

RWTexture3D<uint> output_atomic : register(u0);

void VoxelAtomicAverage(inout RWTexture3D<uint> output, in uint3 dest, in float4 color)
{
	float4 addingColor = float4(color.rgb, 1);
	uint newValue = PackVoxelColor(float4(addingColor.rgb, 1.0 / MAX_VOXEL_ALPHA));
	uint expectedValue = 0;
	uint actualValue;

	InterlockedCompareExchange(output[dest], expectedValue, newValue, actualValue);
	while (actualValue != expectedValue)
	{
		expectedValue = actualValue;

		color = UnpackVoxelColor(actualValue);
		color.a *= MAX_VOXEL_ALPHA;

		color.rgb *= color.a;

		color += addingColor;

		color.rgb /= color.a;

		color.a /= MAX_VOXEL_ALPHA;
		newValue = PackVoxelColor(color);

		InterlockedCompareExchange(output[dest], expectedValue, newValue, actualValue);
	}
}

// Note: centroid interpolation is used to avoid floating voxels in some cases
struct PSInput
{
	float4 pos : SV_POSITION;
	centroid float4 color : COLOR;
	float4 uvsets : UVSETS;
	centroid float3 N : NORMAL;
	centroid float3 P : POSITION3D;

#ifdef VOXELIZATION_CONSERVATIVE_RASTERIZATION_ENABLED
	nointerpolation float3 aabb_min : AABB_MIN;
	nointerpolation float3 aabb_max : AABB_MAX;
#endif // VOXELIZATION_CONSERVATIVE_RASTERIZATION_ENABLED
};

void main(PSInput input)
{
	float3 P = input.P;

	VoxelClipMap clipmap = GetFrame().vxgi.clipmaps[g_xVoxelizer.clipmap_index];
	float3 uvw = GetFrame().vxgi.world_to_clipmap(P, clipmap);
	if (!is_saturated(uvw))
		return;

#ifdef VOXELIZATION_CONSERVATIVE_RASTERIZATION_ENABLED
	uint3 clipmap_pixel = uvw * GetFrame().vxgi.resolution;
	float3 clipmap_uvw_center = (clipmap_pixel + 0.5) * GetFrame().vxgi.resolution_rcp;
	float3 voxel_center = GetFrame().vxgi.clipmap_to_world(clipmap_uvw_center, clipmap);
	AABB voxel_aabb;
	voxel_aabb.c = voxel_center;
	voxel_aabb.e = clipmap.voxelSize;
	AABB triangle_aabb;
	AABBfromMinMax(triangle_aabb, input.aabb_min, input.aabb_max);
	if (!IntersectAABB(voxel_aabb, triangle_aabb))
		return;
#endif // VOXELIZATION_CONSERVATIVE_RASTERIZATION_ENABLED

	float4 baseColor = input.color;
	[branch]
	if (GetMaterial().textures[BASECOLORMAP].IsValid() && (GetFrame().options & OPTION_BIT_DISABLE_ALBEDO_MAPS) == 0)
	{
		float lod_bias = 0;
		if (GetMaterial().options & SHADERMATERIAL_OPTION_BIT_TRANSPARENT || GetMaterial().alphaTest > 0)
		{
			// If material is non opaque, then we apply bias to avoid sampling such a low
			//	mip level in which alpha is completely gone (helps with trees)
			lod_bias = -10;
		}
		baseColor *= GetMaterial().textures[BASECOLORMAP].SampleBias(sampler_linear_wrap, input.uvsets, lod_bias);
	}

	float3 emissiveColor = GetMaterial().GetEmissive();
	[branch]
	if (any(emissiveColor) && GetMaterial().textures[EMISSIVEMAP].IsValid())
	{
		float4 emissiveMap = GetMaterial().textures[EMISSIVEMAP].Sample(sampler_linear_wrap, input.uvsets);
		emissiveColor *= emissiveMap.rgb * emissiveMap.a;
	}

	float3 N = normalize(input.N);

	Lighting lighting;
	lighting.create(0, 0, 0, 0);

	[branch]
	if (any(xForwardLightMask))
	{
		// Loop through light buckets for the draw call:
		const uint first_item = 0;
		const uint last_item = first_item + GetFrame().lightarray_count - 1;
		const uint first_bucket = first_item / 32;
		const uint last_bucket = min(last_item / 32, 1); // only 2 buckets max (uint2) for forward pass!
		[loop]
		for (uint bucket = first_bucket; bucket <= last_bucket; ++bucket)
		{
			uint bucket_bits = xForwardLightMask[bucket];

			[loop]
			while (bucket_bits != 0)
			{
				// Retrieve global entity index from local bucket, then remove bit from local bucket:
				const uint bucket_bit_index = firstbitlow(bucket_bits);
				const uint entity_index = bucket * 32 + bucket_bit_index;
				bucket_bits ^= 1u << bucket_bit_index;

				ShaderEntity light = load_entity(GetFrame().lightarray_offset + entity_index);

				if (light.GetFlags() & ENTITY_FLAG_LIGHT_STATIC)
				{
					continue; // static lights will be skipped (they are used in lightmap baking)
				}

				switch (light.GetType())
				{
				case ENTITY_TYPE_DIRECTIONALLIGHT:
				{
					float3 L = light.GetDirection();
					const float NdotL = saturate(dot(L, N));

					[branch]
					if (NdotL > 0)
					{
						float3 lightColor = light.GetColor().rgb * NdotL;

						[branch]
						if (light.IsCastingShadow() >= 0)
						{
							[loop]
							for (uint cascade = 0; cascade < GetFrame().shadow_cascade_count; ++cascade)
							{
								const float3 shadow_pos = mul(load_entitymatrix(light.GetMatrixIndex() + cascade), float4(P, 1)).xyz; // ortho matrix, no divide by .w
								const float3 shadow_uv = shadow_pos.xyz * float3(0.5f, -0.5f, 0.5f) + 0.5f;

								if (is_saturated(shadow_uv))
								{
									lightColor *= shadow_2D(light, shadow_pos, shadow_uv.xy, cascade);
									break;
								}
							}

							if (GetFrame().options & OPTION_BIT_VOLUMETRICCLOUDS_SHADOWS)
							{
								lightColor *= shadow_2D_volumetricclouds(P);
							}
						}

						lighting.direct.diffuse += lightColor;
					}
				}
				break;
				case ENTITY_TYPE_POINTLIGHT:
				{
					float3 L = light.position - P;
					const float dist2 = dot(L, L);
					const float range = light.GetRange();
					const float range2 = range * range;

					[branch]
					if (dist2 < range2)
					{
						const float3 Lunnormalized = L;
						const float dist = sqrt(dist2);
						L /= dist;
						const float NdotL = saturate(dot(L, N));

						[branch]
						if (NdotL > 0)
						{
							float3 lightColor = light.GetColor().rgb * NdotL * attenuation_pointlight(dist, dist2, range, range2);

							[branch]
							if (light.IsCastingShadow() >= 0) {
								lightColor *= shadow_cube(light, Lunnormalized);
							}

							lighting.direct.diffuse += lightColor;
						}
					}
				}
				break;
				case ENTITY_TYPE_SPOTLIGHT:
				{
					float3 L = light.position - P;
					const float dist2 = dot(L, L);
					const float range = light.GetRange();
					const float range2 = range * range;

					[branch]
					if (dist2 < range2)
					{
						const float dist = sqrt(dist2);
						L /= dist;
						const float NdotL = saturate(dot(L, N));

						[branch]
						if (NdotL > 0)
						{
							const float spot_factor = dot(L, light.GetDirection());
							const float spot_cutoff = light.GetConeAngleCos();

							[branch]
							if (spot_factor > spot_cutoff)
							{
								float3 lightColor = light.GetColor().rgb * NdotL * attenuation_spotlight(dist, dist2, range, range2, spot_factor, light.GetAngleScale(), light.GetAngleOffset());

								[branch]
								if (light.IsCastingShadow() >= 0)
								{
									float4 ShPos = mul(load_entitymatrix(light.GetMatrixIndex() + 0), float4(P, 1));
									ShPos.xyz /= ShPos.w;
									float2 ShTex = ShPos.xy * float2(0.5f, -0.5f) + float2(0.5f, 0.5f);
									[branch]
									if ((saturate(ShTex.x) == ShTex.x) && (saturate(ShTex.y) == ShTex.y))
									{
										lightColor *= shadow_2D(light, ShPos.xyz, ShTex.xy, 0);
									}
								}

								lighting.direct.diffuse += lightColor;
							}
						}
					}
				}
				break;
				}
			}
		}
	}

	// output:
	uint3 writecoord = floor(uvw * GetFrame().vxgi.resolution);

	float3 aniso_direction = N;
	float3 face_offsets = float3(
		aniso_direction.x > 0 ? 0 : 1,
		aniso_direction.y > 0 ? 2 : 3,
		aniso_direction.z > 0 ? 4 : 5
		) * GetFrame().vxgi.resolution;
	float3 direction_weights = abs(N);

	writecoord.z *= VOXELIZATION_CHANNEL_COUNT; // de-interleaved channels

	if (direction_weights.x > 0)
	{
		float4 baseColor_direction = baseColor * direction_weights.x;
		float3 emissive_direction = emissiveColor * direction_weights.x;
		float3 directLight_direction = lighting.direct.diffuse * direction_weights.x;
		float2 normal_direction = encode_oct(N * direction_weights.x) * 0.5 + 0.5;
		InterlockedAdd(output_atomic[writecoord + uint3(face_offsets.x, 0, VOXELIZATION_CHANNEL_BASECOLOR_R)], PackVoxelChannel(baseColor_direction.r));
		InterlockedAdd(output_atomic[writecoord + uint3(face_offsets.x, 0, VOXELIZATION_CHANNEL_BASECOLOR_G)], PackVoxelChannel(baseColor_direction.g));
		InterlockedAdd(output_atomic[writecoord + uint3(face_offsets.x, 0, VOXELIZATION_CHANNEL_BASECOLOR_B)], PackVoxelChannel(baseColor_direction.b));
		InterlockedAdd(output_atomic[writecoord + uint3(face_offsets.x, 0, VOXELIZATION_CHANNEL_BASECOLOR_A)], PackVoxelChannel(baseColor_direction.a));
		InterlockedAdd(output_atomic[writecoord + uint3(face_offsets.x, 0, VOXELIZATION_CHANNEL_EMISSIVE_R)], PackVoxelChannel(emissive_direction.r));
		InterlockedAdd(output_atomic[writecoord + uint3(face_offsets.x, 0, VOXELIZATION_CHANNEL_EMISSIVE_G)], PackVoxelChannel(emissive_direction.g));
		InterlockedAdd(output_atomic[writecoord + uint3(face_offsets.x, 0, VOXELIZATION_CHANNEL_EMISSIVE_B)], PackVoxelChannel(emissive_direction.b));
		InterlockedAdd(output_atomic[writecoord + uint3(face_offsets.x, 0, VOXELIZATION_CHANNEL_DIRECTLIGHT_R)], PackVoxelChannel(directLight_direction.r));
		InterlockedAdd(output_atomic[writecoord + uint3(face_offsets.x, 0, VOXELIZATION_CHANNEL_DIRECTLIGHT_G)], PackVoxelChannel(directLight_direction.g));
		InterlockedAdd(output_atomic[writecoord + uint3(face_offsets.x, 0, VOXELIZATION_CHANNEL_DIRECTLIGHT_B)], PackVoxelChannel(directLight_direction.b));
		InterlockedAdd(output_atomic[writecoord + uint3(face_offsets.x, 0, VOXELIZATION_CHANNEL_NORMAL_R)], PackVoxelChannel(normal_direction.r));
		InterlockedAdd(output_atomic[writecoord + uint3(face_offsets.x, 0, VOXELIZATION_CHANNEL_NORMAL_G)], PackVoxelChannel(normal_direction.g));
		InterlockedAdd(output_atomic[writecoord + uint3(face_offsets.x, 0, VOXELIZATION_CHANNEL_FRAGMENT_COUNTER)], 1);
	}
	if (direction_weights.y > 0)
	{
		float4 baseColor_direction = baseColor * direction_weights.y;
		float3 emissive_direction = emissiveColor * direction_weights.y;
		float3 directLight_direction = lighting.direct.diffuse * direction_weights.y;
		float2 normal_direction = encode_oct(N * direction_weights.y) * 0.5 + 0.5;
		InterlockedAdd(output_atomic[writecoord + uint3(face_offsets.y, 0, VOXELIZATION_CHANNEL_BASECOLOR_R)], PackVoxelChannel(baseColor_direction.r));
		InterlockedAdd(output_atomic[writecoord + uint3(face_offsets.y, 0, VOXELIZATION_CHANNEL_BASECOLOR_G)], PackVoxelChannel(baseColor_direction.g));
		InterlockedAdd(output_atomic[writecoord + uint3(face_offsets.y, 0, VOXELIZATION_CHANNEL_BASECOLOR_B)], PackVoxelChannel(baseColor_direction.b));
		InterlockedAdd(output_atomic[writecoord + uint3(face_offsets.y, 0, VOXELIZATION_CHANNEL_BASECOLOR_A)], PackVoxelChannel(baseColor_direction.a));
		InterlockedAdd(output_atomic[writecoord + uint3(face_offsets.y, 0, VOXELIZATION_CHANNEL_EMISSIVE_R)], PackVoxelChannel(emissive_direction.r));
		InterlockedAdd(output_atomic[writecoord + uint3(face_offsets.y, 0, VOXELIZATION_CHANNEL_EMISSIVE_G)], PackVoxelChannel(emissive_direction.g));
		InterlockedAdd(output_atomic[writecoord + uint3(face_offsets.y, 0, VOXELIZATION_CHANNEL_EMISSIVE_B)], PackVoxelChannel(emissive_direction.b));
		InterlockedAdd(output_atomic[writecoord + uint3(face_offsets.y, 0, VOXELIZATION_CHANNEL_DIRECTLIGHT_R)], PackVoxelChannel(directLight_direction.r));
		InterlockedAdd(output_atomic[writecoord + uint3(face_offsets.y, 0, VOXELIZATION_CHANNEL_DIRECTLIGHT_G)], PackVoxelChannel(directLight_direction.g));
		InterlockedAdd(output_atomic[writecoord + uint3(face_offsets.y, 0, VOXELIZATION_CHANNEL_DIRECTLIGHT_B)], PackVoxelChannel(directLight_direction.b));
		InterlockedAdd(output_atomic[writecoord + uint3(face_offsets.y, 0, VOXELIZATION_CHANNEL_NORMAL_R)], PackVoxelChannel(normal_direction.r));
		InterlockedAdd(output_atomic[writecoord + uint3(face_offsets.y, 0, VOXELIZATION_CHANNEL_NORMAL_G)], PackVoxelChannel(normal_direction.g));
		InterlockedAdd(output_atomic[writecoord + uint3(face_offsets.y, 0, VOXELIZATION_CHANNEL_FRAGMENT_COUNTER)], 1);
	}
	if (direction_weights.z > 0)
	{
		float4 baseColor_direction = baseColor * direction_weights.z;
		float3 emissive_direction = emissiveColor * direction_weights.z;
		float3 directLight_direction = lighting.direct.diffuse * direction_weights.z;
		float2 normal_direction = encode_oct(N * direction_weights.z) * 0.5 + 0.5;
		InterlockedAdd(output_atomic[writecoord + uint3(face_offsets.z, 0, VOXELIZATION_CHANNEL_BASECOLOR_R)], PackVoxelChannel(baseColor_direction.r));
		InterlockedAdd(output_atomic[writecoord + uint3(face_offsets.z, 0, VOXELIZATION_CHANNEL_BASECOLOR_G)], PackVoxelChannel(baseColor_direction.g));
		InterlockedAdd(output_atomic[writecoord + uint3(face_offsets.z, 0, VOXELIZATION_CHANNEL_BASECOLOR_B)], PackVoxelChannel(baseColor_direction.b));
		InterlockedAdd(output_atomic[writecoord + uint3(face_offsets.z, 0, VOXELIZATION_CHANNEL_BASECOLOR_A)], PackVoxelChannel(baseColor_direction.a));
		InterlockedAdd(output_atomic[writecoord + uint3(face_offsets.z, 0, VOXELIZATION_CHANNEL_EMISSIVE_R)], PackVoxelChannel(emissive_direction.r));
		InterlockedAdd(output_atomic[writecoord + uint3(face_offsets.z, 0, VOXELIZATION_CHANNEL_EMISSIVE_G)], PackVoxelChannel(emissive_direction.g));
		InterlockedAdd(output_atomic[writecoord + uint3(face_offsets.z, 0, VOXELIZATION_CHANNEL_EMISSIVE_B)], PackVoxelChannel(emissive_direction.b));
		InterlockedAdd(output_atomic[writecoord + uint3(face_offsets.z, 0, VOXELIZATION_CHANNEL_DIRECTLIGHT_R)], PackVoxelChannel(directLight_direction.r));
		InterlockedAdd(output_atomic[writecoord + uint3(face_offsets.z, 0, VOXELIZATION_CHANNEL_DIRECTLIGHT_G)], PackVoxelChannel(directLight_direction.g));
		InterlockedAdd(output_atomic[writecoord + uint3(face_offsets.z, 0, VOXELIZATION_CHANNEL_DIRECTLIGHT_B)], PackVoxelChannel(directLight_direction.b));
		InterlockedAdd(output_atomic[writecoord + uint3(face_offsets.z, 0, VOXELIZATION_CHANNEL_NORMAL_R)], PackVoxelChannel(normal_direction.r));
		InterlockedAdd(output_atomic[writecoord + uint3(face_offsets.z, 0, VOXELIZATION_CHANNEL_NORMAL_G)], PackVoxelChannel(normal_direction.g));
		InterlockedAdd(output_atomic[writecoord + uint3(face_offsets.z, 0, VOXELIZATION_CHANNEL_FRAGMENT_COUNTER)], 1);
	}


//#if 0
//	uint face_offset = cubemap_to_uv(aniso_direction).z * GetFrame().vxgi.resolution;
//	VoxelAtomicAverage(output_radiance, writecoord + uint3(face_offset, 0, 0), color);
//	VoxelAtomicAverage(output_opacity, writecoord + uint3(face_offset, 0, 0), color.aaaa);
//#else
//	float3 face_offsets = float3(
//		aniso_direction.x > 0 ? 0 : 1,
//		aniso_direction.y > 0 ? 2 : 3,
//		aniso_direction.z > 0 ? 4 : 5
//		) * GetFrame().vxgi.resolution;
//	float3 direction_weights = abs(N);
//	VoxelAtomicAverage(output_radiance, writecoord + uint3(face_offsets.x, 0, 0), color * direction_weights.x);
//	VoxelAtomicAverage(output_radiance, writecoord + uint3(face_offsets.y, 0, 0), color * direction_weights.y);
//	VoxelAtomicAverage(output_radiance, writecoord + uint3(face_offsets.z, 0, 0), color * direction_weights.z);
//	VoxelAtomicAverage(output_opacity, writecoord + uint3(face_offsets.x, 0, 0), color.aaaa * direction_weights.x);
//	VoxelAtomicAverage(output_opacity, writecoord + uint3(face_offsets.y, 0, 0), color.aaaa * direction_weights.y);
//	VoxelAtomicAverage(output_opacity, writecoord + uint3(face_offsets.z, 0, 0), color.aaaa * direction_weights.z);
//#endif

	//bool done = false;
	//while (!done)
	//{
	//	// acquire lock:
	//	uint locked;
	//	InterlockedCompareExchange(lock[writecoord], 0, 1, locked);
	//	if (locked == 0)
	//	{
	//		float4 average = output_albedo[writecoord];
	//		float3 average_normal = output_normal[writecoord];

	//		average.a += 1;
	//		average.rgb += color.rgb;
	//		average_normal.rgb += N * 0.5 + 0.5;

	//		output_albedo[writecoord] = average;
	//		output_normal[writecoord] = average_normal;

	//		InterlockedExchange(lock[writecoord], 0, locked);
	//		done = true;
	//	}
	//}
}
