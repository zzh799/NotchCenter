# Vendor: mediaremote-adapter

上游：[ungive/mediaremote-adapter](https://github.com/ungive/mediaremote-adapter)
固定版本：见 `UPSTREAM_COMMIT`（本仓只跟随固定 commit，不跟随 master）
许可：BSD 3-Clause，见 `LICENSE`（原始版权声明保留在各文件头部，未做修改）

## 为什么在本仓

macOS 15.4 起，系统只放行 bundle id 以 `com.apple.*` 开头的进程访问私有框架
MediaRemote。NotchCenter 是无沙盒、ad-hoc 签名的进程，直连查询恒返回空（本机实测：
同一份二进制在自建 `.app` 里返回空，在 `/usr/bin/perl` 里返回数据）。上游做的事就是
把查询代码放进 `/usr/bin/perl`（bundle id 恰是 `com.apple.perl`）进程里跑：

```
/usr/bin/perl mediaremote-adapter.pl <framework> stream --no-diff --no-artwork
```

配套的 helper framework 由本仓 `scripts/build.sh` 的 `build_mediaremote_bridge()`
用 clang 直接编（不引入 CMake），产物落在 `.build/bridge/`，再由 `assemble_bundle()`
复制进 `BRIDGE_PLUGIN_IDS` 白名单插件的 `Contents/Resources/Bridge/`。

机制与判定依据见 [`docs/agents/系统集成与多语言.md`](../../docs/agents/系统集成与多语言.md)
的「私有框架访问」一节。

## 纳入了什么、没纳入什么

纳入（即本仓实际编译的子集）：

- `src/adapter/{env,get,globals,keys,now_playing,repeat,seek,send,shuffle,speed,stream}.{h,m}`
- `src/private/{MediaRemote.h,MediaRemote.m}`
- `src/utility/{Debounce,helpers}.{h,m}`
- `include/MediaRemoteAdapter.h`
- `bin/mediaremote-adapter.pl`

未纳入（上游 `CMakeLists.txt` 里另有对应 target，本仓不构建）：

- `src/adapter/test.m` 与 `src/test/*`：`test` 自检命令与其独立的 TestClient 可执行文件。
  本仓不用 `test`，故一并省掉；`seek / shuffle / repeat / speed` 等命令的源码在编译子集内
  但本仓不调用，保留是为了少一处与上游的差异。
- `CMakeLists.txt` 保留在目录里只作**构建参考**（记录上游的编译选项与链接框架），
  本仓不执行它，因此它引用的 test 相关文件在本目录不存在。

## 升级方式

1. 取上游新 commit，重下上述纳入清单里的文件（保持原样，不要就地改）。
2. 更新 `UPSTREAM_COMMIT`。
3. `./scripts/build.sh dev` 会因源码指纹变化重编桥；确认 `bridge_fingerprint` 命中重编
   （日志里的 `Building MediaRemote bridge`）。
4. 跑 `./scripts/build.sh test` 与真机冒烟（能读到曲目、能暂停/切歌）。
