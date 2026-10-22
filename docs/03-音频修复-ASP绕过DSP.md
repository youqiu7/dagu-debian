# 音频音质修复：绕过 CS35L41 DSP（Protection 算法）— 2026-10-20

设备：Xiaomi Pad 5 Pro 12.4（dagu），四路 CS35L41 + WCD9385
问题：音量拉满仍然小，音质"很糊、缺细节、没高频没低频"

---

## 1. 根因

**CS35L41 的 DSP 加载了 `Protection` 算法，本质是动态范围压缩器。**

```
Protection = 防破音限幅
副作用     = 压掉瞬态、削平峰值、动态范围变窄
听感       = 平、闷、糊、没有冲击力和空气感
```

这不是 EQ 能补偿的 —— EQ 只改频响，改不了被压掉的动态。

而且 `Protection` 在信号链下游（DSP 内部），PipeWire 侧的 EQ 提升会被它重新压回去，
所以 **+12 dB 的提升几乎听不出来**。

### 为什么只能是 Protection

```
/lib/firmware/cirrus/     只有 spk-cali.bin 和 spk-prot.bin
                          没有 spk-music.bin / *-music.txt
Android super 分区        搜遍也没有 music 算法固件
结论                      Music(高保真) 算法在这台设备上根本不存在
```

---

## 2. 修复：`PCM Source` 从 DSP 改为 ASP

CS35L41 的 `PCM Source` 是二选一 enum：

```
Item #0  ASP   ← 音频串口直通，跳过内部 DSP
Item #1  DSP   ← 经过 DSP（Protection 算法），默认值
```

```bash
for a in TL TR BL BR; do
    amixer -c0 cset name="$a PCM Source" 0   # 0 = ASP
done
```

**效果**：立刻摆脱 Protection，动态和细节大幅恢复。用户实测反馈"比刚才好听多了"。

**风险**：理论上可能无声（功放若依赖 DSP 做初始化）。实测这台设备 ASP 路径正常出声，
且 `alsactl store` 已备份原始状态（`/root/asound.state.backup`），可随时回滚：

```bash
for a in TL TR BL BR; do amixer -c0 cset name="$a PCM Source" 1; done
```

---

## 3. 音量：UCM 会重置，必须改源文件

**现象**：手动把 `Digital PCM` 拉满到 913、`Analog PCM` 到 20，放首歌又变回 817/18。

**原因**：UCM 每次路由时执行 `cset`，把原厂默认值重新写回去。

`/usr/share/alsa/ucm2/Xiaomi-dagu/HiFi.conf` 原始值：

```
cset "name='TL Analog PCM Volume' 18"
cset "name='TL Digital PCM Volume' 817"
```

**修复**：直接改 UCM 源文件

```
Analog PCM Volume  18  → 20   (上限)
Digital PCM Volume 817 → 913  (上限)
```

改完必须重新触发 UCM 路由（重启 pipewire 或切换 sink）才生效。

**限值参考**：

```
Digital PCM Volume   min=0 max=913
Analog PCM Volume    min=0 max=20   (dBscale-min=0.50dB, step=1.00dB)
```

---

## 4. 持久化清单

| 项目 | 位置 | 状态 |
|---|---|---|
| `PCM Source = ASP` | UCM `HiFi.conf` 的 cset | ✅ 已改 |
| 音量 913 / 20 | UCM `HiFi.conf` 的 cset | ✅ 已改 |
| mixer 快照 | `alsactl store` → `/var/lib/alsa/asound.state` | ✅ 已存 |
| 备份 | `/root/asound.state.backup`、`/root/HiFi.conf.dsp-backup` | ✅ |

---

## 5. EQ（PipeWire filter-chain）

**位置**：`~youqi/.config/pipewire/pipewire.conf.d/10-dagu-eq.conf`

**结构**：6 段 biquad，`capture.props.media.class = Audio/Sink` 建虚拟 sink，
`playback.props.node.target` 显式指向 `alsa_output.platform-sound.HiFi__Speaker__sink`。

**当前曲线**（ASP 直通路径下调过）：

| 频段 | 类型 | 增益 |
|---|---|---|
| 80 Hz | Lowshelf | +6.0 dB |
| 250 Hz | Bell | +1.5 dB |
| 700 Hz | Bell | −1.5 dB |
| 2.5 kHz | Bell | +1.5 dB |
| 4.5 kHz | Bell | +5.0 dB |
| 8 kHz | Highshelf | +5.0 dB |

**踩过的坑**：

1. **配置文件放错目录**：`filter-chain.conf.d/` 不会被自动加载，必须放 `pipewire.conf.d/`
2. **重启后立刻查节点会误判**：filter-chain 实例创建有几秒延迟，`pw-cli list-objects | grep dagu_eq`
   应看到 8 个匹配才算建成
3. **`eq_band` 节点不会出现在 `pw-cli` 列表里**：它是 SPA 图内部节点，不是 PipeWire 对象 —— 不能用它判断 EQ 是否生效
4. **`amixer sset` 对 `access=rw------` 的控件无效**：必须用 `cset numid=<N>` 或完整 name
5. **`+12 dB` 会破音**：EQ 生效后 `+6/+5` 是安全上限

**验证 EQ 是否真的生效**：把低频增益推到 +12 dB，放歌听 —— 如果低频明显轰鸣/破音，说明链路通了；
完全无变化则说明 filter-chain 没建起来。

---

## 6. 采样率：48 kHz / 24-bit 是硬上限

```
UCM 注释        Hardware PCM is 2ch S24_LE 48 kHz
PlaybackRate    48000
PlaybackFormat  S24_LE
```

CS35L41 的 DSP 固件固定 48 kHz。设 96/192 kHz 只会让 PipeWire 重采样后再塞回 48 kHz，
多一次失真、零收益。

**48 kHz / 24-bit 本身已是高保真水平**（CD 是 44.1/16）。"不够高清"的观感来自
Protection 的动态压缩，不是采样率。

---

## 7. 原厂调音参考：能做到的边界

**已采用**：

```
UCM HiFi.conf        就是照 Android mixer_paths_overlay_static.xml 写的
DRE Switch           动态范围增强，原厂开
Analog/Digital PCM   原厂增益值（现在拉到上限）
```

**无法采用**：

```
Dolby / Dirac / MiSound   在 Android audio HAL（vendor/lib64/soundfx/*.so）
                          ARM64 Android ELF + bionic，glibc 下无法加载
```

**结论**：原厂调音能参考的部分作者已经做进 UCM 了；音质的本质提升靠 `PCM Source = ASP`
绕过 Protection，而不是继续调 EQ。

---

## 8. 安装包已同步

`dagu-debian-20261020/firmware/ucm/Xiaomi-dagu/HiFi.conf`：

```
PCM Source        ASP（四路）
Analog PCM        20（四路）
Digital PCM       913（四路）
```

---

## 9. 音量链路与 Easy Effects（最终方案）

### 9.1 三层音量，只有一层是真的

| 层 | 对象 | 能否调音量 | 说明 |
|---|---|---|---|
| 虚拟 sink | `easyeffects_sink` | **不能** | filter-chain 的 capture 没有 channelmix 节点，`wpctl set-volume` 数值能写但完全不生效 |
| 硬件 sink | `内置音频 Speakers` | **能** | PipeWire 软件音量（PCM 采样乘算），ALSA 混音器不动 |
| ALSA 混音器 | `Digital PCM` 913 | **能** | 硬件级，`amixer` 直接改 |

`wpctl set-volume <硬件> 0.5` 后 ALSA 仍是 913，证明 PipeWire 走的是软件音量。

### 9.2 正确架构：默认走硬件，easyeffects 拦截

```
设置     process-all-outputs = true
效果     easyeffects 直接拦截硬件 sink，在中间插插件链
默认输出 保持「内置音频 Speakers」→ 音量条控制它（有效）
```

**不要**把 `easyeffects_sink` 设为默认 —— 那是死路（9.1 已证明它不处理音量）。

### 9.3 虚拟 sink 不能删（实测教训）

**删掉 `easyeffects_sink` 后 EQ 立即失效。**

原因是它是 filter-chain 的入口 capture 节点：应用的声音先进这个 sink，才进插件链。
`pw-cli destroy` 之后链断了，声音直接落到硬件，没有任何处理。

试过但**都不行**的隐藏方法：

```
node.hidden 运行时 pw-cli set-param   → 无效（必须在节点创建时设置）
wireplumber node.rules + update-props → 0.5 上没生效
easyeffects 自身设置                  → 没有隐藏 sink 的选项
```

**结论：接受设备列表里有两个输出设备。** 这是 PipeWire filter-chain 的固有结构，不是配置问题。

### 9.4 常驻方式

`easyeffects -w`（隐藏窗口）会退出 —— 没有窗口时 GApplication 结束。
必须用 `--gapplication-service`。

**打开 GUI**：应用列表点 Easy Effects，或命令行 `easyeffects`（激活已有实例）。

### 9.5 踩坑记录

1. 默认设 `easyeffects_sink` 调音量 → **无效**（filter-chain 不处理音量）
2. `wireplumber` 的 `51-dagu-default-sink.conf` 强制默认 → **方向错了**，已删除
3. `node.rules` + `node.hidden` → **wireplumber 0.5 没生效**
4. `pw-cli set-param Props '{node.hidden: true}'` → **运行时无效**
5. `pw-cli destroy-object` → **命令不存在**，正确的是 `pw-cli destroy <id>`
6. `ExecStartPost` 写进 `[Install]` → **systemd 忽略**

### 9.6 常用插件（按需加）

```
Equalizer       图形 EQ，实时拖曲线
Bass Enhancer   补低频（CS35L41 下潜有限）
Crystalizer     补高频细节
Limiter         链尾防破音
```

**建议**：`PCM Source = ASP` 已经拿到主要提升，插件越少失真越小。


