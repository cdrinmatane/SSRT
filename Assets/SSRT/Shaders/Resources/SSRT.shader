// SSRT. Copyright (c) 2019 CDRIN. MIT license (see LICENSE file)

Shader "Hidden/SSRT"
{
	CGINCLUDE
		#include "SSRTLib.cginc"
	ENDCG

	SubShader
	{
		ZTest Always
		Cull Off
		ZWrite Off

		Pass // 0
		{ 
			Name "SSRT"
			CGPROGRAM 
				#pragma target 4.0
				#pragma vertex vert
				#pragma fragment frag
				
				void frag(v2f input, out float3 BentNormalWorld : SV_Target0, out float4 GIOcclusion : SV_Target1)
				{
					float2 uv = input.uv.xy;
					uv += (1.0 / _ScreenParams.xy) * (_ResolutionDownscale == 1 ? 0 : 0.5);
					GIOcclusion = 0;
					BentNormalWorld = SSRT(uv, _RotationCount, _StepCount, GIOcclusion);
				}
			ENDCG 
		}
		
		Pass // 1
		{
			Name "Upsample"
			CGPROGRAM
			#pragma vertex vert
			#pragma fragment frag
			
			float4 frag(v2f input) : SV_Target
			{
				float2 uv = input.uv.xy;
				float depth = LinearEyeDepth(tex2D(_CameraDepthTexture, uv).x);
				half3 normalWorld = normalize(tex2D(_CameraGBufferTexture2, uv).rgb * 2 - 1);

				float pixelMultiplier = ((float)_ResolutionDownscale / 2.0) * (1.0 / _ScreenParams.xy);
				
				float4 uv00 = float4(uv + float2(-1.0, 0.0) * pixelMultiplier, 0, 0);
				float4 uv10 = float4(uv + float2(1.0, 0.0) * pixelMultiplier, 0, 0);
				float4 uv11 = float4(uv + float2(0.0, 1.0) * pixelMultiplier, 0, 0);
				float4 uv01 = float4(uv + float2(0.0, -1.0) * pixelMultiplier, 0, 0);

				float4 sample00 = tex2Dlod(_GIOcclusionTexture, uv00);
				float4 sample10 = tex2Dlod(_GIOcclusionTexture, uv10);
				float4 sample11 = tex2Dlod(_GIOcclusionTexture, uv11);
				float4 sample01 = tex2Dlod(_GIOcclusionTexture, uv01);

				float4 depthSamples = float4(0,0,0,0);
				depthSamples.x = LinearEyeDepth(tex2Dlod(_CurrentDepth, uv00).x);
				depthSamples.y = LinearEyeDepth(tex2Dlod(_CurrentDepth, uv10).x);
				depthSamples.z = LinearEyeDepth(tex2Dlod(_CurrentDepth, uv11).x);
				depthSamples.w = LinearEyeDepth(tex2Dlod(_CurrentDepth, uv01).x);

				half3 normal00 = normalize(tex2Dlod(_CurrentNormal, uv00).rgb * 2 - 1);
				half3 normal10 = normalize(tex2Dlod(_CurrentNormal, uv10).rgb * 2 - 1);
				half3 normal11 = normalize(tex2Dlod(_CurrentNormal, uv11).rgb * 2 - 1);
				half3 normal01 = normalize(tex2Dlod(_CurrentNormal, uv01).rgb * 2 - 1);

				float4 weights = float4(1,1,1,1);
				weights.x = distance(depthSamples.x, depth);
				weights.y = distance(depthSamples.y, depth);
				weights.z = distance(depthSamples.z, depth);
				weights.w = distance(depthSamples.w, depth);

				weights.x *= (1 - saturate(dot(normal00, normalWorld)));
				weights.y *= (1 - saturate(dot(normal10, normalWorld)));
				weights.z *= (1 - saturate(dot(normal11, normalWorld)));
				weights.w *= (1 - saturate(dot(normal01, normalWorld)));

				float minValue = min(min(min(weights.x, weights.y), weights.z), weights.w);

				float4 result = 0;
				if (minValue == weights.x)
				{
					result = sample00;
				}
				else if (minValue == weights.y)
				{
					result = sample10;
				}
				else if (minValue == weights.z)
				{
					result = sample11;
				}
				else if (minValue == weights.w)
				{
					result = sample01;
				}

				return result;
			}
			ENDCG
		}
		
		Pass // 2
		{ 
			Name "SampleReuse"
			CGPROGRAM 
				#pragma vertex vert
				#pragma fragment frag
				
				float4 frag(v2f input) : SV_Target
				{
					float2 uv = input.uv.xy;
					
					float depth = LinearEyeDepth(tex2Dlod(_CameraDepthTexture, float4(uv, 0.0, 0.0)).x);
					float3 normalWorld = tex2D (_CameraGBufferTexture2, uv).rgb * 2 - 1;
					float4 result = 0;
					
					float weightSum = 0.0;
					for(int i = 0; i < _ReuseCount; i++)
					{
						float2 offsetUV = offset[i] * (1.0 / _ScreenParams.xy);
						
						float2 neighborUv = uv + offsetUV;
						
						float reuseDepth = LinearEyeDepth(tex2Dlod(_CameraDepthTexture, float4(neighborUv, 0.0, 0.0)).x);
						float3 reuseNormal = tex2D (_CameraGBufferTexture2, neighborUv).rgb * 2 - 1;
						float4 sampleColor = tex2Dlod(_FilterTexture1, float4(neighborUv, 0, 0));
						
						float thresh = 0.4;
						float weight = 1.0;
						weight *= saturate((1.0 - saturate(distance(depth, reuseDepth) / thresh)) * 1);
						weight *= pow(saturate(dot(reuseNormal, normalWorld)), 5.0);
						

						result += sampleColor * weight;
						weightSum += weight;
					}
					result /= weightSum;
					
					return result.rgba;
				}
			ENDCG 
		}

		Pass // 3
		{ 
			Name "TemporalReproj"
			CGPROGRAM 
				#pragma vertex vert
				#pragma fragment frag
				
			float4 frag(v2f input) : SV_Target
			{
				float2 uv = input.uv.xy; 
				float2 oneOverResolution = (1.0 / _ScreenParams.xy);
				
				float4 gi = tex2D(_FilterTexture1, input.uv.xy);
				float depth = LinearEyeDepth(tex2D(_CameraDepthTexture, input.uv.xy).x);
				float4 currentPos = float4(input.uv.x * 2.0 - 1.0, input.uv.y * 2.0 - 1.0, depth * 2.0 - 1.0, 1.0);
				
				float4 fragpos = mul(_InverseViewProjectionMatrix, float4(float3(uv * 2 - 1, depth), 1));
				fragpos.xyz /= fragpos.w;
				float4 thisWorldPosition = fragpos;
				
				float2 motionVectors = tex2Dlod(_CameraMotionVectorsTexture, float4(input.uv.xy, 0.0, 0.0)).xy;
				float2 reprojCoord = input.uv.xy - motionVectors.xy;
				
				float prevDepth = LinearEyeDepth(tex2Dlod(_PreviousDepth, float4(reprojCoord + oneOverResolution * 0.0, 0.0, 0.0)).x);
				
				float4 previousWorldPosition = mul(_LastFrameInverseViewProjectionMatrix, float4(reprojCoord.xy * 2.0 - 1.0, prevDepth * 2.0 - 1.0, 1.0));
				previousWorldPosition /= previousWorldPosition.w;
				
				float blendWeight = _TemporalResponse;
				
				float posSimilarity = saturate(1.0 - distance(previousWorldPosition.xyz, thisWorldPosition.xyz) * 1.0);
				blendWeight = lerp(1.0, blendWeight, posSimilarity);
				
				float4 minPrev = float4(10000, 10000, 10000, 10000);
				float4 maxPrev = float4(0, 0, 0, 0);

				float4 s0 = tex2Dlod(_FilterTexture1, float4(input.uv.xy + oneOverResolution * float2(0.5, 0.5), 0, 0));
				minPrev = s0;
				maxPrev = s0;
				s0 = tex2Dlod(_FilterTexture1, float4(input.uv.xy + oneOverResolution * float2(0.5, -0.5), 0, 0));
				minPrev = min(minPrev, s0);
				maxPrev = max(maxPrev, s0);
				s0 = tex2Dlod(_FilterTexture1, float4(input.uv.xy + oneOverResolution * float2(-0.5, 0.5), 0, 0));
				minPrev = min(minPrev, s0);
				maxPrev = max(maxPrev, s0);
				s0 = tex2Dlod(_FilterTexture1, float4(input.uv.xy + oneOverResolution * float2(-0.5, -0.5), 0, 0));
				minPrev = min(minPrev, s0);
				maxPrev = max(maxPrev, s0);

				float4 prevGI = tex2Dlod(_PreviousColor, float4(reprojCoord, 0.0, 0.0));
				prevGI = lerp(prevGI, clamp(prevGI, minPrev, maxPrev), 0.25);
				
				gi = lerp(prevGI, gi, float4(blendWeight, blendWeight, blendWeight, blendWeight));
				
				return gi;
			}
			ENDCG 
		}

		Pass // 4
		{
			Name"DebugMode AO"
			CGPROGRAM
			#pragma vertex vert
			#pragma fragment frag
			
			float4 frag(v2f input) : SV_Target
			{
				float2 uv = input.uv.xy;
				float ao = tex2D(_FilterTexture2, uv).a;
				
				if (_MultiBounceAO)
				{
					float3 albedo = tex2D(_CameraGBufferTexture0, uv);
					ao = MultiBounceAO(ao, albedo);
				}
				
				return float4(ao.xxx, 1);
			}
			ENDCG
		}

		Pass // 5
		{ 
			Name"DebugMode BentNormal"
			CGPROGRAM 
				#pragma vertex vert
				#pragma fragment frag
				
			float4 frag(v2f input) : SV_Target
			{
				float2 uv = input.uv.xy;
				return float4(tex2D(_BentNormalTexture, uv).rgb * 0.5 + 0.5, 1);
			}
			ENDCG 
		}

		Pass // 6
		{
			Name"DebugMode GI"
			CGPROGRAM
			#pragma vertex vert
			#pragma fragment frag
			
			float4 frag(v2f input) : SV_Target
			{
				float2 uv = input.uv.xy;
				float3 albedo = _LightOnly ? 1 : tex2D(_CameraGBufferTexture0, uv.xy).rgb;
				float4 GTAOGI = tex2D(_FilterTexture2, uv).rgba;
				float3 ambient = _LightOnly ? 0 : tex2D(_AmbientTexture, uv).rgb;
				
				if (_MultiBounceAO)
				{
					GTAOGI.a = MultiBounceAO(GTAOGI.a, albedo);
				}

				float3 SceneColor = GTAOGI.rgb * albedo + ambient * GTAOGI.a;

				return float4(SceneColor, 1);
			}
			ENDCG
		}

		Pass // 7
		{
			Name"DebugMode Combined"
			CGPROGRAM
			#pragma vertex vert
			#pragma fragment frag
			
			float4 frag(v2f input) : SV_Target
			{
				float2 uv = input.uv.xy;

				float3 albedo = _LightOnly ? 1 : tex2D(_CameraGBufferTexture0, uv.xy).rgb;
				float4 GTAOGI = tex2D(_FilterTexture2, uv);
				float3 ambient = _LightOnly ? 0 : tex2D(_AmbientTexture, uv).rgb;
				float3 directLighting = tex2D(_CameraTexture, uv).rgb * (_DirectLightingAO ? GTAOGI.a : 1);
				
				if (_MultiBounceAO)
				{
					GTAOGI.a = MultiBounceAO(GTAOGI.a, albedo);
				}

				float3 CameraColor = GTAOGI.rgb * albedo + directLighting + ambient * GTAOGI.a;

				return float4(CameraColor, 1);
			}
			ENDCG
		}

		Pass // 8
		{
			Name"GetDepth"
			CGPROGRAM
			#pragma vertex vert
			#pragma fragment frag
			
			float4 frag(v2f input) : COLOR0
			{
				float2 coord = input.uv.xy + (1.0 / _ScreenParams.xy) * 0.5;
				float4 tex = tex2D(_CameraDepthTexture, coord);
				return tex;
			}
			ENDCG
		}

		Pass // 9
		{
			Name"GetNormal"
			CGPROGRAM
			#pragma vertex vert
			#pragma fragment frag
			
			float4 frag(v2f input) : COLOR0
			{
				float2 coord = input.uv.xy + (1.0 / _ScreenParams.xy) * 0.5;
				float4 tex = tex2D(_CameraGBufferTexture2, coord);
				return tex;
			}
			
			ENDCG
		}
		
		Pass // 10
		{
			Name"GetLightmask"
			CGPROGRAM
			#pragma vertex vert
			#pragma fragment frag

			float4 frag(v2f input) : COLOR0
			{
				float2 coord = input.uv.xy;
				float3 tex = (tex2D(_CameraGBufferTexture3, coord).rgb + tex2D(_AmbientTexture, coord).rgb);
				return float4(tex, 1);
			}
			
			ENDCG
		}
	}
}

