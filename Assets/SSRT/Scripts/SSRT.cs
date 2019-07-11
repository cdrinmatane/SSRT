// SSRT. Copyright (c) 2019 CDRIN. MIT license (see LICENSE file)

using UnityEngine;
using UnityEngine.Rendering;

[RequireComponent(typeof(Camera))]
public class SSRT : MonoBehaviour 
{
	#region Properties
	public enum DebugMode { AO = RenderPass.DebugModeAO, BentNormal = RenderPass.DebugModeBentNormal, GI = RenderPass.DebugModeGI, Combined = RenderPass.DebugModeCombined }
	public enum FallbackMethod { Off = 0, StaticIrradianceCubemap = 1, DynamicCubemap = 2}
	public enum ResolutionDownscale { Full = 1, Half = 2, Quarter = 4, Eight = 8 }
	public enum RenderPass { SSRT = 0, Upsample = 1, SampleReuse = 2, TemporalReproj = 3, DebugModeAO = 4, DebugModeBentNormal = 5, DebugModeGI = 6, 
		DebugModeCombined = 7, GetDepth = 8, GetNormal = 9, GetLightmask = 10, CopyLightmask = 11 }
		
	public readonly string version = "1.0.0";

	[Header("Sampling")]
	[Tooltip("Number of directionnal rotations applied during sampling.")]
	[Range(1, 4)] 
	public int rotationCount = 4;
	[Tooltip("Number of samples taken along one edge of the current conic slice.")]
	[Range(1, 16)] 
	public int stepCount = 8;
	[Tooltip("Effective sampling radius in world space. AO and GI can only have influence within that radius.")]
	[Range(1, 25)] 
	public float radius = 3.5f;
	[Tooltip("Controls samples distribution. Exp Start is an initial multiplier on the step size, and Exp Factor is an exponent applied at each step. By using a start value < 1, and an exponent > 1, it's possible to get exponential step size.")]
	[Range(0.1f, 1)] 
	public float expStart = 1f;
	[Tooltip("Controls samples distribution. Exp Start is an initial multiplier on the step size, and Exp Factor is an exponent applied at each step. By using a start value < 1, and an exponent > 1, it's possible to get exponential step size.")]
	[Range(1, 2)] 
	public float expFactor = 1f;
	[Tooltip("Applies some noise on sample positions to hide the banding artifacts that can occur when there is undersampling.")]
	public bool jitterSamples = true;

	[Header("GI")]
	[Tooltip("Intensity of the indirect diffuse light.")]
	[Range(0, 75)] 
	public float GIBoost = 20;
	[Tooltip("Using an HDR light buffer gives more accurate lighting but have an impact on performances.")]
	public bool lightBufferHDR = false;
	[Tooltip("Using lower resolution light buffer can help performances but can accentuate aliasing.")]
	public ResolutionDownscale lightBufferResolution = ResolutionDownscale.Half;
	[Tooltip("Bypass the dot(lightNormal, lightDirection) weighting.")]
	[Range(0, 1)] 
	public float LnDlOffset = 0.0f;
	[Tooltip("Bypass the dot(normal, lightDirection) weighting.")]
	[Range(0, 1)] 
	public float nDlOffset = 0.0f;

	[Header("Occlusion")]
	[Tooltip("Power function applied to AO to make it appear darker/lighter.")]
	[Range(1, 8)] 
	public float power = 1.5f;
	[Tooltip("Constant thickness value of objects on the screen in world space. Is used to ignore occlusion past that thickness level, as if light can travel behind the object.")]
	[Range(0.1f, 10)] 
	public float thickness = 10f;
	[Tooltip("Occlusion falloff relative to distance.")]
	[Range(1, 50)] 
	public float falloff = 1f;
	[Tooltip("Multi-Bounce analytic approximation from GTAO.")]
	public bool multiBounceAO = false;
	[Tooltip("Composite AO also on direct lighting.")]
	public bool directLightingAO = false;

	[Header("Offscreen Fallback")]
	[Tooltip("Ambient lighting to use. Off uses the Unity ambient lighting, but it's possible to use instead a static irradiance cubemap (pre-convolved), or render a cubemap around camera every frame (expensive).")]
	public FallbackMethod fallbackMethod = FallbackMethod.Off;
	[Tooltip("Static irradiance cubemap to use if it's the chosen fallback.")]
	public Cubemap cubemapFallback;

	[Header("Filters")]
	[Tooltip("The resolution at which SSRT is computed. If lower than fullscreen the effect will be upscaled to fullscreen afterwards. Lower resolution can help performances but can also introduce more flickering/aliasing.")]
	public ResolutionDownscale resolutionDownscale = ResolutionDownscale.Half;
	[Tooltip("Number of neighbor pixel to reuse (helps reduce noise).")]
	[Range(1, 8)] 
	public int reuseCount = 5;
	[Tooltip("Enable/Disable temporal reprojection")]
	public bool temporalEnabled = true;
	[Tooltip("Controls the speed of the accumulation, slower accumulation is more effective at removing noise but can introduce ghosting.")]
	[Range(0, 1)] 
	public float temporalResponse = 0.35f;

	[Header("Debug Mode")]
	[Tooltip("View of the different SSRT buffers for debug purposes.")]
	public DebugMode debugMode = DebugMode.Combined;
	[Tooltip("If enabled will show only the radiance that affects the surface, if unchecked radiance will be multiplied by surface albedo.")]
	public bool lightOnly = false;
	#endregion

	#region Rendering
	void GenerateCommandBuffers()
	{
		ssrtBuffer.Clear();
		storeAmbientBuffer.Clear();
		clearBuffer.Clear();
		
		//// Clear the main RT to avoid feedback loop (Before GBuffer)
		clearBuffer.SetRenderTarget(BuiltinRenderTextureType.CameraTarget);
		clearBuffer.ClearRenderTarget(false, true, Color.black);

		//// Store ambient color (before lighting)
		storeAmbientBuffer.Blit(BuiltinRenderTextureType.CameraTarget, ambientTexture);
		//// Remove ambient color from GBuffer3 (keep only direct lighting in lightmask)
		storeAmbientBuffer.SetRenderTarget(BuiltinRenderTextureType.CameraTarget);
		storeAmbientBuffer.ClearRenderTarget(false, true, Color.black);

		//// Store direct lighting
		var cameraColorID = Shader.PropertyToID("_CameraTexture");
		ssrtBuffer.GetTemporaryRT(cameraColorID, (int)renderResolution.x, (int)renderResolution.y, 0, FilterMode.Point, RenderTextureFormat.DefaultHDR);
		ssrtBuffer.Blit(BuiltinRenderTextureType.CameraTarget, cameraColorID);

		//// Lightmask generation: direct lighting + ambientTexture -> lightmask
		var lightmaskID = Shader.PropertyToID("_LightmaskTexture");
		ssrtBuffer.GetTemporaryRT(lightmaskID, (int)renderResolution.x / (int)lightBufferResolution, (int)renderResolution.y / (int)lightBufferResolution, 0, FilterMode.Point, lightBufferHDR ? RenderTextureFormat.DefaultHDR : RenderTextureFormat.ARGB32);
		ssrtBuffer.SetRenderTarget(lightmaskID);
		ssrtBuffer.DrawMesh(mesh, Matrix4x4.identity, ssrtMaterial, 0, (int)RenderPass.GetLightmask);

		//// SSRT marching
		RenderTargetIdentifier[] ssrtMrtID = { ssrtMrt[0] /* Bent Normals */, ssrtMrt[1] /* GIColorOcclusion */};
		ssrtBuffer.SetRenderTarget(ssrtMrtID, ssrtMrt[1] /* Useless */);
		ssrtBuffer.DrawMesh(mesh, Matrix4x4.identity, ssrtMaterial, 0, (int)RenderPass.SSRT);
		
		var filterTexture1ID = Shader.PropertyToID("_FilterTexture1");
		ssrtBuffer.GetTemporaryRT(filterTexture1ID, (int)renderResolution.x, (int)renderResolution.y, 0, FilterMode.Point, RenderTextureFormat.DefaultHDR);
		var filterTexture2ID = Shader.PropertyToID("_FilterTexture2");
		ssrtBuffer.GetTemporaryRT(filterTexture2ID, (int)renderResolution.x, (int)renderResolution.y, 0, FilterMode.Point, RenderTextureFormat.DefaultHDR);

		//// Bilateral Upsampling
		if (resolutionDownscale != ResolutionDownscale.Full)
		{
			var currentDepthID = Shader.PropertyToID("_CurrentDepth");
			ssrtBuffer.GetTemporaryRT(currentDepthID, (int)renderResolution.x / (int)resolutionDownscale, (int)renderResolution.y / (int)resolutionDownscale, 0, FilterMode.Point, RenderTextureFormat.RFloat, RenderTextureReadWrite.Linear);
			var currentNormalID = Shader.PropertyToID("_CurrentNormal");
			ssrtBuffer.GetTemporaryRT(currentNormalID, (int)renderResolution.x / (int)resolutionDownscale, (int)renderResolution.y / (int)resolutionDownscale, 0, FilterMode.Point, RenderTextureFormat.ARGBHalf, RenderTextureReadWrite.Linear);

			ssrtBuffer.SetRenderTarget(currentDepthID);
			ssrtBuffer.DrawMesh(mesh, Matrix4x4.identity, ssrtMaterial, 0, (int)RenderPass.GetDepth);

			ssrtBuffer.SetRenderTarget(currentNormalID);
			ssrtBuffer.DrawMesh(mesh, Matrix4x4.identity, ssrtMaterial, 0, (int)RenderPass.GetNormal);

			ssrtBuffer.SetRenderTarget(filterTexture1ID);
			ssrtBuffer.DrawMesh(mesh, Matrix4x4.identity, ssrtMaterial, 0, (int)RenderPass.Upsample);
		}
		else
		{
			ssrtBuffer.Blit(ssrtMrt[1], filterTexture1ID);
		}

		//// Reuse samples (filterTexture1ID -> filterTexture2ID -> filterTexture1ID)
		if (reuseCount > 1)
		{
			ssrtBuffer.SetRenderTarget(filterTexture2ID);
			ssrtBuffer.DrawMesh(mesh, Matrix4x4.identity, ssrtMaterial, 0, (int)RenderPass.SampleReuse);
			ssrtBuffer.CopyTexture(filterTexture2ID, filterTexture1ID);
		}

		//// Temporal filter (filterTexture1ID -> filterTexture2ID)
		if (temporalEnabled)
		{
			ssrtBuffer.SetRenderTarget(filterTexture2ID);
			ssrtBuffer.DrawMesh(mesh, Matrix4x4.identity, ssrtMaterial, 0, (int)RenderPass.TemporalReproj);
			ssrtBuffer.Blit(filterTexture2ID, previousFrameTexture);
			
			ssrtBuffer.SetRenderTarget(previousDepthTexture);
			ssrtBuffer.DrawMesh(mesh, Matrix4x4.identity, ssrtMaterial, 0, (int)RenderPass.GetDepth);
		}
		else
		{
			ssrtBuffer.Blit(filterTexture1ID, filterTexture2ID);
		}

		//// Final composite pass
		ssrtBuffer.SetRenderTarget(BuiltinRenderTextureType.CameraTarget);
		ssrtBuffer.DrawMesh(mesh, Matrix4x4.identity, ssrtMaterial, 0, (int)debugMode);

		lastFrameViewProjectionMatrix = viewProjectionMatrix;
		lastFrameInverseViewProjectionMatrix = viewProjectionMatrix.inverse;
	}

	void UpdateVariables()
	{
		var worldToCameraMatrix = cam.worldToCameraMatrix;
		ssrtMaterial.SetMatrix("_CameraToWorldMatrix", worldToCameraMatrix.inverse);
		var projectionMatrix = GL.GetGPUProjectionMatrix(cam.projectionMatrix, false);
		ssrtMaterial.SetMatrix("_InverseProjectionMatrix", projectionMatrix.inverse);
		viewProjectionMatrix = projectionMatrix * worldToCameraMatrix;
		ssrtMaterial.SetMatrix("_InverseViewProjectionMatrix", viewProjectionMatrix.inverse);
		ssrtMaterial.SetMatrix("_LastFrameViewProjectionMatrix", lastFrameViewProjectionMatrix);
		ssrtMaterial.SetMatrix("_LastFrameInverseViewProjectionMatrix", lastFrameInverseViewProjectionMatrix);
		ssrtMaterial.SetInt("_RotationCount", rotationCount);
		ssrtMaterial.SetInt("_StepCount", stepCount);
		ssrtMaterial.SetFloat("_GIBoost", GIBoost);
		ssrtMaterial.SetFloat("_LnDlOffset", LnDlOffset);
		ssrtMaterial.SetFloat("_NDlOffset", nDlOffset);
		ssrtMaterial.SetFloat("_Radius", radius);
		ssrtMaterial.SetFloat("_ExpStart", expStart);
		ssrtMaterial.SetFloat("_ExpFactor", expFactor);
		ssrtMaterial.SetFloat("_Thickness", thickness);
		ssrtMaterial.SetFloat("_Falloff", falloff);
		ssrtMaterial.SetFloat("_Power", power);
		ssrtMaterial.SetFloat("_TemporalResponse", temporalResponse);
		ssrtMaterial.SetInt("_MultiBounceAO", multiBounceAO ? 1 : 0);
        ssrtMaterial.SetFloat("_DirectLightingAO", directLightingAO ? 1 : 0);
		ssrtMaterial.SetTexture("_CubemapFallback", cubemapFallback);
		ssrtMaterial.SetInt("_FallbackMethod", (int)fallbackMethod);
		ssrtMaterial.SetInt("_LightOnly", lightOnly ? 1 : 0);
		ssrtMaterial.SetInt("_ReuseCount", reuseCount);
		ssrtMaterial.SetInt("_JitterSamples", jitterSamples ? 1 : 0);

		float projScale;
		projScale = (float)renderResolution.y / (Mathf.Tan(cam.fieldOfView * Mathf.Deg2Rad * 0.5f) * 2) * 0.5f;
		ssrtMaterial.SetFloat("_HalfProjScale", projScale);
		ssrtMaterial.SetInt("_ResolutionDownscale", (int)resolutionDownscale);

		// From Activision GTAO paper: https://www.activision.com/cdn/research/s2016_pbs_activision_occlusion.pptx
		float temporalRotation = temporalRotations[Time.frameCount % 6];
		float temporalOffset = spatialOffsets[(Time.frameCount /* / 6*/) % (resolutionDownscale == ResolutionDownscale.Full ? 4 : 2)];
		ssrtMaterial.SetFloat("_TemporalDirections", temporalRotation / 360);
		ssrtMaterial.SetFloat("_TemporalOffsets", temporalOffset);

		if (cameraSize != renderResolution / (float)resolutionDownscale)
		{
			cameraSize = renderResolution / (float) resolutionDownscale;
			
			if (ssrtMrt[0] != null) ssrtMrt[0].Release();
			ssrtMrt[0] = new RenderTexture((int)renderResolution.x / (int)resolutionDownscale, (int)renderResolution.y / (int)resolutionDownscale, 0, RenderTextureFormat.ARGBHalf);
			ssrtMrt[0].filterMode = FilterMode.Point;
			ssrtMrt[0].Create();

			if (ssrtMrt[1] != null) ssrtMrt[1].Release();
			ssrtMrt[1] = new RenderTexture((int)renderResolution.x / (int)resolutionDownscale, (int)renderResolution.y / (int)resolutionDownscale, 0, RenderTextureFormat.DefaultHDR);
			ssrtMrt[1].filterMode = FilterMode.Point;
			ssrtMrt[1].Create();
			
			if (ambientTexture != null) ambientTexture.Release();
			ambientTexture = new RenderTexture((int)renderResolution.x, (int)renderResolution.y, 0, RenderTextureFormat.DefaultHDR);

			if (previousFrameTexture != null) previousFrameTexture.Release();
			previousFrameTexture = new RenderTexture((int)renderResolution.x, (int)renderResolution.y, 0, RenderTextureFormat.DefaultHDR);
			previousFrameTexture.filterMode = FilterMode.Point;
			previousFrameTexture.Create();
			
			if (previousDepthTexture != null) previousDepthTexture.Release();
			previousDepthTexture = new RenderTexture((int)renderResolution.x, (int)renderResolution.y, 0, RenderTextureFormat.RFloat);
			previousDepthTexture.filterMode = FilterMode.Point;
			previousDepthTexture.Create();
		}

		ssrtMaterial.SetTexture("_BentNormalTexture", ssrtMrt[0]);
		ssrtMaterial.SetTexture("_GIOcclusionTexture", ssrtMrt[1]);
		ssrtMaterial.SetTexture("_AmbientTexture", ambientTexture);
		ssrtMaterial.SetTexture("_PreviousColor", previousFrameTexture);
		ssrtMaterial.SetTexture("_PreviousDepth", previousDepthTexture);
	}

	void RenderCubemap()
	{
		if (cubemapCamera == null)
		{
			var BackCamera = new GameObject("CubemapCamera", typeof(Camera));
			BackCamera.transform.SetParent(cam.transform);
			cubemapCamera = BackCamera.GetComponent<Camera>();
			cubemapCamera.CopyFrom(cam);
			cubemapCamera.enabled = false;
			cubemapCamera.renderingPath = RenderingPath.Forward;
		}
		if (cubemapFallback)
			cubemapCamera.RenderToCubemap(cubemapFallback, 1 << Time.frameCount % 6 /*63*/);
	}
	#endregion
	
	#region CreationDestruction
	Camera cam;
	Camera cubemapCamera;
	Material ssrtMaterial;
	CommandBuffer ssrtBuffer = null;
	CommandBuffer storeAmbientBuffer = null;
	CommandBuffer clearBuffer = null;
	Mesh mesh;

	Matrix4x4 lastFrameViewProjectionMatrix;
	Matrix4x4 viewProjectionMatrix;
	Matrix4x4 lastFrameInverseViewProjectionMatrix;
	Vector2 cameraSize;
	Vector2 renderResolution;

	RenderTexture ambientTexture;
	RenderTexture previousFrameTexture;
	RenderTexture previousDepthTexture;
	RenderTexture[] ssrtMrt = new RenderTexture[2];

	// From Activision GTAO paper: https://www.activision.com/cdn/research/s2016_pbs_activision_occlusion.pptx
	static readonly float[] temporalRotations = { 60, 300, 180, 240, 120, 0 };
	static readonly float[] spatialOffsets = { 0, 0.5f, 0.25f, 0.75f };

	void Awake()
	{
		cam = gameObject.GetComponent<Camera>();
		cam.depthTextureMode |= DepthTextureMode.Depth | DepthTextureMode.MotionVectors;

		ssrtMaterial = new Material(Shader.Find("Hidden/SSRT"));
		
		mesh = new Mesh();
		mesh.vertices = new Vector3[]
		{
			new Vector3(-1, -1, 1),
			new Vector3(-1, 1, 1),
			new Vector3(1, 1, 1),
			new Vector3(1, -1, 1)
		};
		mesh.uv = new Vector2[]
		{
			new Vector2(0, 1),
			new Vector2(0, 0),
			new Vector2(1, 0),
			new Vector2(1, 1)
		};
		mesh.SetIndices(new int[] { 0, 1, 2, 3 }, MeshTopology.Quads, 0);

		if(fallbackMethod == FallbackMethod.DynamicCubemap)
		{
			cubemapFallback = new Cubemap(32, TextureFormat.RGB24, true);
			cubemapFallback.Apply(true);
		}
	}

	void OnPreRender()
	{
		renderResolution = new Vector2(cam.pixelWidth, cam.pixelHeight);

        if ((renderResolution.x % 2 == 1 || renderResolution.y % 2 == 1) && resolutionDownscale != ResolutionDownscale.Full)
        {
            Debug.LogWarning("SSRT: Using uneven camera resolution (" + renderResolution.x + ", " + renderResolution.y + 
				") with downscaling can introduce artifacts! Use a fixed resolution instead of free aspect.");
        }

		if (ssrtBuffer != null)
		{
			if (fallbackMethod == FallbackMethod.DynamicCubemap && Application.isPlaying)
			{
				RenderCubemap();
			}
			UpdateVariables();
			GenerateCommandBuffers();
		}
	}

	void OnEnable()
	{
		ssrtBuffer = new CommandBuffer();
		ssrtBuffer.name = "SSRT";
		storeAmbientBuffer = new CommandBuffer();
		storeAmbientBuffer.name = "StoreAmbient";
		clearBuffer = new CommandBuffer();
		clearBuffer.name = "ClearBuffer";
		cam.AddCommandBuffer(CameraEvent.BeforeImageEffectsOpaque, ssrtBuffer);
		cam.AddCommandBuffer(CameraEvent.BeforeLighting, storeAmbientBuffer);
		cam.AddCommandBuffer(CameraEvent.BeforeGBuffer, clearBuffer);
	}

	void OnDisable()
	{
		if (ssrtBuffer != null) {
			cam.RemoveCommandBuffer(CameraEvent.BeforeImageEffectsOpaque, ssrtBuffer);
			ssrtBuffer = null;
		}
		if (storeAmbientBuffer != null)
		{
			cam.RemoveCommandBuffer(CameraEvent.BeforeLighting, storeAmbientBuffer);
			storeAmbientBuffer = null;
		}
		if (clearBuffer != null)
		{
			cam.RemoveCommandBuffer(CameraEvent.BeforeGBuffer, clearBuffer);
			clearBuffer = null;
		}
	}

	void OnDestroy()
	{
		if (ssrtMrt[0] != null)
		{
			ssrtMrt[0].Release();
			ssrtMrt[0] = null;
		}

		if (ssrtMrt[1] != null)
		{
			ssrtMrt[1].Release();
			ssrtMrt[1] = null;
		}

		if (ambientTexture != null)
		{
			ambientTexture.Release();
			ambientTexture = null;
		}

		if (previousFrameTexture != null)
		{
			previousFrameTexture.Release();
			previousFrameTexture = null;
		}

		if (previousDepthTexture != null)
		{
			previousDepthTexture.Release();
			previousDepthTexture = null;
		}

		if (ssrtBuffer != null) 
		{
			ssrtBuffer.Dispose();
			ssrtBuffer = null;
		}

		if (storeAmbientBuffer != null)
		{
			storeAmbientBuffer.Dispose();
			storeAmbientBuffer = null;
		}

		if (clearBuffer != null)
		{
			clearBuffer.Dispose();
			clearBuffer = null;
		}
	}
	#endregion
}