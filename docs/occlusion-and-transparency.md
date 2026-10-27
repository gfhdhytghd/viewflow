# Occlusion, viewport clipping, and transparent precomposition

The full sparse patch policy below is implemented for the Hyprland-to-Windows
forward atlas. Native window routes use a different wire format. They now
support destination viewport residency as described below, but do not yet use
the forward atlas's alpha-cell classification or multi-patch occlusion policy.

## Native window route viewport residency

Linux→Mac, Windows→Mac, Mac→Linux, and Mac→Windows sources accept viewport
feedback from the destination. A window keeps its full geometry, identity,
input coordinates, and lifetime while only one resident rectangle occupies
atlas slots. A fully off-screen or minimized window retains metadata with an
empty resident rectangle; revealing it restores pixels from the next completed
frame. No source-desktop stacking or window-style flag is treated as evidence
that a destination pixel is hidden.

Destinations round the requested area outward, add 256 source pixels of
prefetch, then align outward to a 128-pixel grid. Multiple displays use a
conservative bounding rectangle. Mac and Windows presenters report minimized
windows as empty; the Linux presenter currently uses monitor bounds, retaining
pixels for non-visible workspaces and covered windows. Capture buffers remain
full-sized for recovery. Linux and Windows native sources resize their encoded
canvas to the requested residency; Mac keeps its popup reserve but releases a
sustained large unused canvas after demand settles and pending encoding drains.
The Mac log reports full, resident, and encoded-canvas pixel counts separately.

The native protocol advertises source capability bit 512. Updated receivers
send visibility record kind 16 only after that capability appears; updated
sources send crop extension bit 256 only after feedback. Upgrade receivers
before sources: old receivers reject the new source capability. A crop's pixel
mapping is carried with its encoded frame and alpha, preserving the old image
until the matching new decoded frame completes.

| Optimization | Hyprland→Windows forward atlas | Native window routes involving Mac |
| --- | --- | --- |
| Outside viewport pixel residency | Sparse patches, seam cache | One resident rectangle, seam prefetch |
| Fully transparent cell removal | GPU alpha classification | Not implemented |
| Lower pixels hidden by opaque windows | Conservative GPU cell rejection | Not implemented |
| Transparent overlap precomposition | Optional `prerender` | Not implemented |
| Window metadata retained with zero pixels | Yes | Yes |
| Capture uses only visible area | No, full capture buffers | No, full capture buffers |

These are equivalent viewport savings, not full parity with every forward-atlas
optimization. No live input or focus change is required to test the crop math,
wire representation, or owned-buffer encode/decode path.

The source JSON accepts `"occlusion": "opaque"` (default), `"prerender"`, or
`"off"`. The paired launcher exposes the same setting as
`--occlusion opaque|prerender|off`. Both the Rust receiver and the Windows native
presenter must support sparse patches; capability checks reject older peers
before publication.

## What occupies the atlas

Window geometry, stacking, input ownership, and lifetime are separate from
resident pixel patches. Sources are split on a shared physical 128-pixel grid,
with exact smaller patches at window and viewport boundaries. GPU alpha
classification examines the prepared RGBA pixels, including repaired shadows;
only compact cell summaries return to the CPU. No color image is downloaded
for visibility decisions.

Fully transparent cells consume no atlas slots. In `opaque` mode, a front cell
removes a lower cell only when its alpha is exactly opaque and it completely
covers that lower cell. Partial coverage, unknown stacking, different capture
scales, and fractional grid placement conservatively retain independent
layers. Native style flags are not evidence of opacity.

The remote desktop viewport defines display and input clipping. Pixel residency
also includes a bounded strip beyond a shared edge with the configured local
display: `desktop.seam_cache_dip` defaults to 256 logical pixels, accepts 0 to
1024, and 0 disables this prefetch. Only an adjoining edge expands; gaps and
corner-only contact do not. Already-enrolled windows can reveal these cached
pixels while the next source frame is still in flight. The wire viewport, full
window bounds, native HWND region, and input coordinates remain unchanged.

A window farther outside than the cache strip retains its metadata but has no
resident patches. Partial pixels round outward at fractional scales. Residency
is refreshed in each completed frame, rather than retaining old pixels across
unrelated atlas mappings. This also applies when stacking is unknown. Ordinary
viewport departure does not mean the window was closed. Prefetch does not
start capture of unrelated local windows before their normal enrollment.

Windows proxies display cropped sprites referencing shared atlas surfaces.
They do not allocate a full texture for each window. The atlas uses two shared
composition surfaces so new pixels can be staged before changing bindings.

## Transparency option

`opaque` preserves independent transparent layers and retains a 256-capture-pixel
underlay halo near mixed-alpha cells for receiver backdrop blur. This halo is
conservative at ordinary matching scales, not a proof for arbitrary blur and
cross-display scaling combinations.

`prerender` additionally composites visible remote layers bottom-to-top when
they have exactly the same cell footprint, and sends the resulting patch on
the top window. Different boundary footprints remain independent. This saves
space under transparent overlaps, at the cost of independent local-window
interleaving and potentially different backdrop-blur results. Movement can
briefly display the previous composition while the next frame arrives. Remaining
alpha still participates in native composition. Use `opaque` when independent
composition is more important than these additional savings.

Patch mapping changes require a new scene revision and paired color/alpha
keyframes. A receiver never retags old atlas pixels with a new patch mapping.
Hidden and revealed patch sets are committed with their completed frame.

## Capacity and limits

Sparse startup warms the codec with an empty canvas rather than allocating the
sum of enrolled window rectangles. Live growth accounts for the largest source
preparation dimensions and required patch slots, up to the negotiated canvas
limit. If slots are exhausted at that limit, topmost visible patches take
priority; other patches are omitted while window metadata and input remain.
A single capture exceeding the maximum supported dimensions is still withheld.
The canvas does not automatically shrink after pixels become hidden.

These savings apply to atlas residency and receiver window backings. Source
capture and RGBA preparation still use full window buffers. Grid padding,
transparent layers, blur underlay, codec surfaces, and double buffering also
consume resources. This is not an unlimited-window or fixed-frame-rate claim.

## Verification

Hardware checks on 2026-09-07 used owned textures, without desktop input:

- GPU alpha classification, opaque rejection, transparent source-over,
  reveal/clear behavior, and grow/retry ownership passed.
- The two-layer 256x256 fixture occupied 131,072 pixels in `opaque` mode and
  65,536 pixels in `prerender` mode. Both modes passed fully off-screen,
  partially visible, and fully restored residency checks on the same encoder.
- Windows composition pixel readback verified source crop coordinates, colors,
  removal without stale pixels, and zero per-window full-size surface backings.
- Protocol and parser tests cover sparse patch validation and fragmented input.

These checks establish the tested behavior, not 8K full-motion throughput.

## 按连接关闭透明度

`desktop-share.json`（atlas 源端）和 `vf-window-peer` 配置支持顶层
`"transparency": false`；省略时为 `true`，保持原有行为。原生 Windows/macOS
源端接受 `VIEWFLOW_TRANSPARENCY=0`，Rust window peer 只给源端子进程传递此设置；
独立 Linux coded 源端也读取此环境变量。旧原生程序忽略该变量，仍可正常连接。

关闭后使用几何矩形 alpha：已知窗口内容区域内部不透明，阴影边距和 atlas 空白
保持透明；无内容矩形信息的 CPU coded 源端使用全不透明平面。圆角、半透明终端、
磨砂效果和真实阴影不再精确保留。Linux 此模式停用依赖真实 alpha 的遮挡裁剪优化。
配置在连接/源进程启动时读取，修改后需重新连接。

CUDA 路径跳过 alpha 比较和 GPU→CPU 下载，并跳过可选的 Rust alpha 拷贝；
macOS 跳过 Metal alpha 提取和 CPU alpha 读取；Windows 不再提交 alpha readback。
VA-API 目前用 CPU 准备颜色，仍需读取 RGBA，但跳过额外的 alpha 提取循环。
矩形掩码仅在几何改变时重建，编码复用已有缓存。此选项不改变输入或连接可用性策略。

不增加网络格式。Atlas 继续使用协商后的 84 字节 `VFAF` 引用，关键帧发送完整
`VFAR`。例如 3840×2160 全不透明平面由现有 RLE 编成 129624 字节
（原始 alpha 为 8294400 字节），稳定非关键帧 alpha 负载约 5040 字节/秒
（60 fps，不含传输头）；每个完整关键帧另加约 126.6 KiB。矩形边缘会略增 RLE
开销，实际节省取决于原 alpha 的复杂度和关键帧频率。Windows 全不透明平面已有
6 字节编码捷径；带透明边距的矩形使用原有 RLE。兼容 coded 路径继续发送常量
VFAR；只有显式协商允许时才可采用 `OpaqueMayOmit`，不能对旧端省略必需的平面。
相对于逐帧读取原始 alpha，4K60 最多省去约 497.7 MB/s 的 alpha 下载；已有的
未变化 alpha 优化会减少此上限。关闭 alpha 遮挡裁剪也可能增加颜色流量，因此不能保证
总码率按此幅度下降。以上为格式计算，非无线网络或实机吞吐测量。
