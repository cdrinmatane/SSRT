// SSRT. Copyright (c) 2019 CDRIN. MIT license (see LICENSE file)

#include "UnityCG.cginc"

// Sampling properties
int _RotationCount;
int _StepCount;
float _Radius;
float _ExpStart;
float _ExpFactor;
int _JitterSamples;

// GI properties
float _GIBoost;
float _LnDlOffset;
float _NDlOffset;

// Occlusion properties
float _Power;
float _Thickness;
float _Falloff;
int _MultiBounceAO;
float _DirectLightingAO;

// Offscreen fallback properties
#define FALLBACK_OFF 0
#define FALLBACK_IRRADIANCE 1
#define FALLBACK_DYNAMIC_CUBEMAP 2

int _FallbackMethod;
samplerCUBE _CubemapFallback;

// Filters properties
int _ResolutionDownscale;
int _ReuseCount;
float _TemporalResponse;

// Debug properties
int _LightOnly;

// Internal parameters
int _FrameCount;
float _HalfProjScale;
float _TemporalOffsets;
float _TemporalDirections;

// Transformation matrices
float4x4 _CameraToWorldMatrix;
float4x4 _InverseProjectionMatrix;
float4x4 _LastFrameViewProjectionMatrix;
float4x4 _InverseViewProjectionMatrix;
float4x4 _LastFrameInverseViewProjectionMatrix;

// Built-in Unity textures
sampler2D _CameraGBufferTexture0;
sampler2D _CameraGBufferTexture1;
sampler2D _CameraGBufferTexture2;
sampler2D _CameraGBufferTexture3;
sampler2D _CameraReflectionsTexture;
sampler2D _CameraMotionVectorsTexture;
sampler2D _CameraDepthTexture;
sampler2D _CameraDepthNormalsTexture;

// Render textures
sampler2D _CameraTexture; // Direct lighting
sampler2D _AmbientTexture; // Ambient + reflection probes
sampler2D _BentNormalTexture;
sampler2D _GIOcclusionTexture; // GI color (RGB), Occlusion (A)
sampler2D _FilterTexture1; // Ping pong texture for various filtering passes
sampler2D _FilterTexture2; // Ping pong texture for various filtering passes
sampler2D _CurrentDepth; // Lower resolution texture used for upscaling
sampler2D _CurrentNormal; // Lower resolution texture used for upscaling
sampler2D _LightmaskTexture;
sampler2D _PreviousColor;
sampler2D _PreviousDepth;

struct appdata
{
	float4 vertex : POSITION;
	float4 uv : TEXCOORD0;
};

struct v2f
{
	float4 pos : SV_POSITION;
	float4 uv : TEXCOORD0;
};

v2f vert(appdata v)
{
	v2f o;
	o.pos = v.vertex;
	o.uv = v.uv;
	return o;
}

static const float2 offset[17] =
{
	float2(0, 0),
	float2(2, -2),
	float2(-2, -2),
	float2(0, 2),

	float2(2, 0),

	float2(0, -2),
	float2(-2, 0),
	float2(-2, 2),
	float2(2, 2),

	float2(4, -4),
	float2(-4, -4),
	float2(0, 4),
	float2(4, 0),

	float2(0, -4),
	float2(-4, 0),
	float2(-4, 4),
	float2(4, 4),
};

// From Activision GTAO paper: https://www.activision.com/cdn/research/s2016_pbs_activision_occlusion.pptx
inline float3 MultiBounceAO(float visibility, float3 albedo)
{
	float3 a = 2.0404 * albedo - 0.3324;
	float3 b = -4.7951 * albedo + 0.6417;
	float3 c = 2.7552 * albedo + 0.6903;
	
	float x = visibility;
	return max(x, ((x * a + b) * x + c) * x);
}

inline float3 PositionSSToVS(float2 uv) 
{
	float logDepth = tex2Dlod(_CameraDepthTexture, float4(uv, 0, 0)).r; 
	float linearDepth = LinearEyeDepth(logDepth);
	
	float3 posVS;
	posVS.xy = uv * 2 - 1;  // Scale from screen [0, 1] to clip [-1, 1]
	posVS.xy = mul((float2x2)_InverseProjectionMatrix, posVS.xy) * linearDepth; // Apply inverse scale/offset, remove w division
	posVS.z = linearDepth;
	return posVS;
}

inline float3 GetNormalVS(float2 uv)
{
	float3 normalWS = tex2Dlod(_CameraGBufferTexture2, float4(uv, 0, 0)).rgb * 2 - 1; 
	float3 normalVS = normalize(mul((float3x3) /*_WorldToCameraMatrix*/UNITY_MATRIX_V, normalWS));
	return float3(normalVS.xy, -normalVS.z);
}

// From Activision GTAO paper: https://www.activision.com/cdn/research/s2016_pbs_activision_occlusion.pptx
inline float SpatialOffsets(float2 uv)
{
	int2 position = (int2)(uv * _ScreenParams.xy);
	return 0.25 * (float)((position.y - position.x) & 3);
}

// Interleaved gradient function from Jimenez 2014 http://goo.gl/eomGso
inline float GradientNoise(float2 position)
{
	return frac(52.9829189 * frac(dot(position, float2( 0.06711056, 0.00583715))));
}

// From Activision GTAO paper: https://www.activision.com/cdn/research/s2016_pbs_activision_occlusion.pptx
float IntegrateArc(float2 h1, float2 h2, float n) 
{
	return 0.25 * (-cos(2 * h1 - n) + cos(n) + 2 * h1 * sin(n)) + 
		   0.25 * (-cos(2 * h2 - n) + cos(n) + 2 * h2 * sin(n));
}

// From http://byteblacksmith.com/improvements-to-the-canonical-one-liner-glsl-rand-for-opengl-es-2-0/
inline float rand(float2 co)
{
	float a = 12.9898;
	float b = 78.233;
	float c = 43758.5453;
	float dt = dot(co.xy, float2(a, b));
	float sn = fmod(dt, 3.14);
	return frac(sin(sn) * c);
}

float4 SSRT(float2 uv, int rotationCount, int stepCount, inout float4 GIOcclusion)
{
	if (tex2D(_CameraDepthTexture, uv).r <= 1e-7)
	{
		GIOcclusion.a = 1;
		return float4(0, 0, 0, 1);
	}
	
	float3 posVS = PositionSSToVS(uv);
	float3 normalVS = GetNormalVS(uv);
	float3 normalWS = tex2D(_CameraGBufferTexture2, uv).rgb * 2 - 1;
	float3 viewDir = normalize(-posVS);

	float radius = _Radius;
	float thickness = 1;

	float noiseOffset = SpatialOffsets(uv);
	float noiseDirection = GradientNoise(uv * _ScreenParams.xy);

	float initialRayStep = frac(noiseOffset + _TemporalOffsets) + (rand(uv) * 2.0 - 1.0) * 0.25 * float(_JitterSamples);

	float ao;
	float2 H;
	float3 bentNormalView;
	float3 col = 0;
	uint sampleCount = 0;

	UNITY_LOOP
	for (int i = 0; i < rotationCount; i++)
	{
		float rotationAngle = (i + noiseDirection + _TemporalDirections) * (UNITY_PI / (float)rotationCount);
		float3 sliceDir = float3(float2(cos(rotationAngle), sin(rotationAngle)), 0);
		float2 slideDir_TexelSize = sliceDir.xy * (1.0 / _ScreenParams.xy);
		float2 h = -1;
		
		float stepRadius = max((radius * _HalfProjScale) / posVS.z, (float)stepCount);
		stepRadius /= ((float)stepCount + 1);
		stepRadius *= _ExpStart;

		UNITY_LOOP
		for (int j = 0; j < stepCount; j++)
		{
			float2 uvOffset = slideDir_TexelSize * max(stepRadius * (j + initialRayStep), 1 + j);
			float2 uvSlice = uv + uvOffset;
			
			if(uvSlice.x <= 0 || uvSlice.y <= 0 || uvSlice.x >= 1 || uvSlice.y >= 1)
				break;
			
			stepRadius *= _ExpFactor;

			float3 ds = PositionSSToVS(uvSlice) - posVS;

			float dds = dot(ds, ds);
			float dsdtLength = rsqrt(dds);

			float falloff = saturate(dds * (2 / pow(radius, 2)) * _Falloff);

			H.x = dot(ds, viewDir) * dsdtLength;
			
			if (H.x > h.x)
			{
				float3 lmA = tex2Dlod(_LightmaskTexture, float4(uvSlice, 0, 0)).rgb;
				if(Luminance(lmA) > 0.0)
				{
					float dsl = length(ds);
					float distA = clamp(dsl, 0.1, 50);
					float attA = clamp(1.0 / (/*3.1416*distA**/distA), 0, 50);
					float3 dsn = normalize(ds);
					float nDlA = saturate(dot(normalVS, dsn) + _NDlOffset);

					if (attA * nDlA > 0.0)
					{
						float3 sliceANormal = GetNormalVS(uvSlice);

						float LnDlA = saturate(dot(sliceANormal, -dsn) + _LnDlOffset);
						col.xyz += attA * lmA * nDlA * LnDlA;
						sampleCount++;
					}
				}
			}
			
			h.x = (H.x > h.x && -(ds.z) < _Thickness) ? lerp(H.x, h.x, falloff) : lerp(H.x, h.x, thickness);
		}
		
		UNITY_LOOP
		for (j = 0; j < stepCount; j++) 
		{
			float2 uvOffset = slideDir_TexelSize * max(stepRadius * (j + initialRayStep), 1 + j);
			float2 uvSlice = uv - uvOffset;
			
			if(uvSlice.x <= 0 || uvSlice.y <= 0 || uvSlice.x >= 1 || uvSlice.y >= 1)
				break;
			
			stepRadius *= _ExpFactor;

			float3 dt = PositionSSToVS(uvSlice) - posVS;

			float ddt = dot(dt, dt);
			float dsdtLength = rsqrt(ddt);

			float falloff = saturate(ddt * (2 / pow(radius, 2)) * _Falloff);

			H = dot(dt, viewDir) * dsdtLength;

			
			if (H.y > h.y)
			{
				float3 lmB = tex2Dlod(_LightmaskTexture, float4(uvSlice, 0, 0)).rgb;
				if(Luminance(lmB) > 0.0)
				{
					float dtl = length(dt);
					float distB = clamp(dtl, 0.1, 50);
					float attB = clamp(1.0 / (/*3.1416*distB**/distB), 0, 50);
					float3 dtn = normalize(dt);
					float nDlB = saturate(dot(normalVS, dtn) + _NDlOffset);

					if (attB * nDlB> 0.0)
					{
						float3 sliceBNormal = GetNormalVS(uvSlice);

						float LnDlB = saturate(dot(sliceBNormal, -dtn) + _LnDlOffset);
						col.xyz += attB * lmB * nDlB * LnDlB;
						sampleCount++;
					}
				}
			}
			
			h.y = (H.y > h.y && -dt.z < _Thickness) ? lerp(H.y, h.y, falloff) : lerp(H.y, h.y, thickness);
		}

		float3 planeNormal = normalize(cross(sliceDir, viewDir));
		float3 tangent = cross(viewDir, planeNormal);
		float3 projectedNormal = normalVS - planeNormal * dot(normalVS, planeNormal);
		float projLength = length(projectedNormal);

		float cos_n = clamp(dot(normalize(projectedNormal), viewDir), -1, 1);
		float n = -sign(dot(projectedNormal, tangent)) * acos(cos_n);

		h = acos(clamp(h, -1, 1));
		h.x = n + max(-h.x - n, -UNITY_HALF_PI);
		h.y = n + min(h.y - n, UNITY_HALF_PI);

		float bentAngle = (h.x + h.y) * 0.5;

		bentNormalView += viewDir * cos(bentAngle) - tangent * sin(bentAngle);
		ao += projLength * IntegrateArc(h.x, h.y, n);
	}

	col /= rotationCount * stepCount * 2;//max(sampleCount, 1);

	bentNormalView = normalize(normalize(bentNormalView) - viewDir * 0.5);
	float3 bentNormalWorld = mul((float3x3)_CameraToWorldMatrix, float3(bentNormalView.rg, -bentNormalView.b));
	
	ao = saturate(pow(ao / (float)rotationCount, _Power));

	float3 fallbackColor = 0;
	if (_FallbackMethod == FALLBACK_IRRADIANCE || _FallbackMethod == FALLBACK_DYNAMIC_CUBEMAP)
	{
		
		float mip = _FallbackMethod == FALLBACK_DYNAMIC_CUBEMAP ? 7 : 0;
		float3 cubemapColor = pow(texCUBElod(_CubemapFallback, float4(bentNormalWorld, mip)), 1);
		fallbackColor = cubemapColor * ao;
	}
	
	GIOcclusion.rgb = fallbackColor + col /** (1- ao)*/ * _GIBoost;
	GIOcclusion.a = ao;

	return float4(bentNormalWorld, 1.0);
}
