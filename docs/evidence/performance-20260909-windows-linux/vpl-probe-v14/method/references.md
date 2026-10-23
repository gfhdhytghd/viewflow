# Primary reference

[Microsoft VideoProcessorSetStreamAutoProcessingMode](https://learn.microsoft.com/en-us/windows/win32/api/d3d11/nf-d3d11-id3d11videocontext-videoprocessorsetstreamautoprocessingmode) says the driver may perform extra processing by default and FALSE disables it. This probe records before/after state and measures the actual hardware, without assuming that enabled means extra work is present.
