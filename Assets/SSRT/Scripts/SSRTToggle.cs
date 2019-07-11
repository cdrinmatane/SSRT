// SSRT. Copyright (c) 2019 CDRIN. MIT license (see LICENSE file)

using UnityEngine;

public class SSRTToggle : MonoBehaviour 
{
	SSRT ssrt;

	void Start () 
	{
		ssrt = GetComponent<SSRT>();
	}
	
	void Update () 
	{
		if(ssrt)
		{
			if (Input.GetKeyDown(KeyCode.Alpha1))
			{
				ssrt.enabled = true;
				ssrt.debugMode = SSRT.DebugMode.Combined;
				ssrt.lightOnly = false;
				ssrt.directLightingAO = false;
			}
			if (Input.GetKeyDown(KeyCode.Alpha3))
			{
				ssrt.enabled = true;
				ssrt.debugMode = SSRT.DebugMode.GI;
				ssrt.lightOnly = false;
			}
			if (Input.GetKeyDown(KeyCode.Alpha2))
			{
				ssrt.enabled = false;
			}
			if (Input.GetKeyDown(KeyCode.Alpha4))
			{
				ssrt.enabled = true;
				ssrt.debugMode = SSRT.DebugMode.GI;
				ssrt.lightOnly = true;
			}
			if (Input.GetKeyDown(KeyCode.Alpha5))
			{
				ssrt.enabled = true;
				ssrt.debugMode = SSRT.DebugMode.Combined;
				ssrt.lightOnly = false;
				ssrt.directLightingAO = true;
			}

			if(Input.GetKeyDown(KeyCode.F))
			{
				ssrt.resolutionDownscale = SSRT.ResolutionDownscale.Full;
			}
			if (Input.GetKeyDown(KeyCode.H))
			{
				ssrt.resolutionDownscale = SSRT.ResolutionDownscale.Half;
			}
		}
	}
}
