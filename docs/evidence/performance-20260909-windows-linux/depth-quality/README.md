# One-task and two-task quality comparison

The same v5 source binary produced 1235 and 1542 recorded frames at explicit depths one and two. All recorded frames passed marker and exact-alpha GPU decode checks. Ninety common markers were compared at every RGB pixel of the complete 6144×3456 image. PSNR is 41.915864 versus 41.916378 dB, MSE 6.433001e-5 versus 6.432240e-5; maximum pixel error is the same. This synthetic grid comparison does not certify natural images or fine text.

The canonical encoder has identical can_submit, submit, drain and poll processing; main differs only by an explicit optional header. Canonical startup changes the default to two and removes an arbitrary allocation cap, while actual QueryIOSurf readback remains three surfaces, identical to the tested two-task variant. The hardware wrapper is byte-identical. Thus quality results apply to the same processing path, with both public modes retaining bitrate, dimensions, format and alpha.
