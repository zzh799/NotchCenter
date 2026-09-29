// 本文件由 web/tools/gen-plugins.mjs 生成，请勿手工编辑。
// 数据源：Plugins/*/Plugin.plist（PluginID / DisplayName / Description / *Locales.zh-Hans）。
// 顺序与插件发现顺序一致（Plugins/* 目录名字典序）。改 Plugin.plist 后请重新运行：
//   node web/tools/gen-plugins.mjs
window.NOTCH_PLUGINS = [
  {
    "dir": "AlbumPlugin",
    "id": "com.notchcenter.album",
    "name": {
      "en": "Album",
      "zh": "相册"
    },
    "desc": {
      "en": "Photo carousel and single-photo blocks, sourced from a local folder or your Photos library.",
      "zh": "文件夹或照片图库的轮播块与单张照片块。"
    }
  },
  {
    "dir": "CaffeinatePlugin",
    "id": "com.notchcenter.caffeinate",
    "name": {
      "en": "Keep Awake",
      "zh": "保持唤醒"
    },
    "desc": {
      "en": "Keeps your Mac awake on demand.",
      "zh": "按需保持你的 Mac 不休眠。"
    }
  },
  {
    "dir": "CalendarPlugin",
    "id": "com.notchcenter.calendar",
    "name": {
      "en": "Calendar",
      "zh": "日历"
    },
    "desc": {
      "en": "Current-month glance with today's lunar date; click opens Calendar.",
      "zh": "当月速览与今日农历，点击打开日历.app。"
    }
  },
  {
    "dir": "CalibrePlugin",
    "id": "com.zhouzihang.notchcenter.calibre",
    "name": {
      "en": "Calibre Server",
      "zh": "Calibre 服务"
    },
    "desc": {
      "en": "Controls the calibre-server launchd service.",
      "zh": "控制 calibre-server launchd 服务。"
    }
  },
  {
    "dir": "CameraPlugin",
    "id": "com.notchcenter.camera",
    "name": {
      "en": "Mirror",
      "zh": "镜子"
    },
    "desc": {
      "en": "Camera mirror preview for checking yourself before a call.",
      "zh": "开会前照一眼的摄像头镜像预览。"
    }
  },
  {
    "dir": "ClipboardHistoryPlugin",
    "id": "com.notchcenter.clipboard",
    "name": {
      "en": "Clipboard History",
      "zh": "剪贴板历史"
    },
    "desc": {
      "en": "Remembers recent copies — text, images, and files; click an entry to copy it back.",
      "zh": "记住最近复制的文本、图片与文件，点击条目即可写回剪贴板。"
    }
  },
  {
    "dir": "ClockPlugin",
    "id": "com.notchcenter.clock",
    "name": {
      "en": "Clock",
      "zh": "时钟"
    },
    "desc": {
      "en": "Analog clock face; click opens Clock.",
      "zh": "指针表盘一瞥即知时间，点击打开时钟.app。"
    }
  },
  {
    "dir": "CommandSchedulerPlugin",
    "id": "com.zhouzihang.notchcenter.commandscheduler",
    "name": {
      "en": "Command Scheduler",
      "zh": "定时命令"
    },
    "desc": {
      "en": "Runs shell commands on a schedule and keeps their output history.",
      "zh": "按计划自动执行本机命令，并保留每次执行的输出历史。"
    }
  },
  {
    "dir": "DisplayPlugin",
    "id": "com.notchcenter.brightness",
    "name": {
      "en": "Display Brightness",
      "zh": "显示器亮度"
    },
    "desc": {
      "en": "Adjust brightness per screen: the built-in display over the system brightness channel, external displays over DDC/CI (Apple Silicon via IOAVService, Intel via IOKit IOI2C).",
      "zh": "按显示器调节亮度：内建屏走系统亮度通道，外接屏走 DDC/CI（Apple Silicon 走 IOAVService，Intel 走 IOKit IOI2C）。"
    }
  },
  {
    "dir": "DshPlugin",
    "id": "com.zhouzihang.notchcenter.dsh",
    "name": {
      "en": "DSH Service",
      "zh": "DSH 服务"
    },
    "desc": {
      "en": "Controls the dsh-web launchd service.",
      "zh": "管理 dsh-web 的 launchd 服务。"
    }
  },
  {
    "dir": "LidAngleDepthPlugin",
    "id": "com.notchcenter.lidangledepth",
    "name": {
      "en": "Lid Depth",
      "zh": "合盖透视"
    },
    "desc": {
      "en": "iPhone Duo style lid effect: screen content tilts, blurs and fades as you close your MacBook.",
      "zh": "iPhone Duo 式合盖效果：合上 MacBook 时屏幕内容随之倾斜、模糊并淡出。"
    }
  },
  {
    "dir": "MediaControlsPlugin",
    "id": "com.notchcenter.media-controls",
    "name": {
      "en": "Media Controls",
      "zh": "媒体控制"
    },
    "desc": {
      "en": "Control the media playing anywhere on this Mac (play/pause, previous, next) from a single row that shows the playing app.",
      "zh": "单行控制系统当前播放的媒体（播放/暂停、上一首、下一首），并显示正在播放的应用。"
    }
  },
  {
    "dir": "NotesPlugin",
    "id": "com.notchcenter.notes",
    "name": {
      "en": "Notes",
      "zh": "笔记"
    },
    "desc": {
      "en": "Markdown notes with TextKit 2 rendering.",
      "zh": "基于 TextKit 2 渲染的 Markdown 笔记。"
    }
  },
  {
    "dir": "PomodoroPlugin",
    "id": "com.notchcenter.pomodoro",
    "name": {
      "en": "Pomodoro",
      "zh": "番茄钟"
    },
    "desc": {
      "en": "Focus timer with random micro-break reminders living in the notch.",
      "zh": "刘海中的专注计时器，按随机间隔提醒你微休息。"
    }
  },
  {
    "dir": "QuickButtonBoxPlugin",
    "id": "com.zhouzihang.notchcenter.quickbuttonbox",
    "name": {
      "en": "Quick Button Box",
      "zh": "快捷按钮盒"
    },
    "desc": {
      "en": "Collects quick actions from other plugins into one drawer grid.",
      "zh": "把其他插件的快捷动作收纳进一个抽屉网格。"
    }
  },
  {
    "dir": "RemindersPlugin",
    "id": "com.notchcenter.reminders",
    "name": {
      "en": "Reminders",
      "zh": "提醒事项"
    },
    "desc": {
      "en": "Your reminder lists in the drawer, checked off in place.",
      "zh": "抽屉里的提醒事项清单，可就地勾选完成。"
    }
  },
  {
    "dir": "ScratchpadPlugin",
    "id": "com.notchcenter.scratchpad",
    "name": {
      "en": "Scratchpad",
      "zh": "暂存区"
    },
    "desc": {
      "en": "A tray that references files you may want later.",
      "zh": "引用你可能稍后需要的文件的暂存架。"
    }
  },
  {
    "dir": "SystemMonitorPlugin",
    "id": "com.notchcenter.system-monitor",
    "name": {
      "en": "System Monitor",
      "zh": "系统监控"
    },
    "desc": {
      "en": "CPU, memory, disk and network load blocks plus an all-in-one overview, with per-instance thresholds, history windows and sampling that idles when the drawer is closed.",
      "zh": "CPU、内存、磁盘、网络负载块与四合一总览块；每实例可调阈值与历史窗口，抽屉收起时自动降频采样。"
    }
  }
];
