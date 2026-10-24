# MaiBot（麦麦）—— PyPI 程序包（wheel）版本，装成一个自带 venv 的独立程序
# 依赖不自己解析版本：直接读上游仓库的 uv.lock，`uv export` 出一份全量 pin 的
# requirements.txt 再装 —— 版本跟得上上游，也不会出现「今天编和昨天编不一样」。
# 三段式，每段各司其职：
#   ① requirements：纯离线跑 `uv export`，把 uv.lock 翻成 pin 清单
#   ② wheels：固定输出（FOD），构建期联网把清单里的 wheel 全下下来（jieba 只有 sdist，
#      顺手编成 wheel）。这一步产物是纯文件，不含任何 /nix/store 引用
#      —— 固定输出不允许引用 store 路径，所以「装包」不能放在这一层
#   ③ 本文件的主体：普通派生，离线把 wheel 铺进 $out 并拼出 venv 骨架
#      （venv 的 shebang / pyvenv.cfg 必须写 $out 的绝对路径，也只有普通派生能这么干）
# 换版本：改 version、wheel 的 url/hash、下面的 rev 与两个 hash，
#        再把 wheels 的 outputHash 填 lib.fakeHash 跑一次 nix build，把报错里的 hash 抄回来。
# 首次构建要下 250MB 左右 wheel，国内直连 PyPI 很慢：挂代理再编
#   nix build --impure-env https_proxy=http://127.0.0.1:7897 …
# 或者传 indexUrl 换镜像。
{
  lib,
  stdenv,
  stdenvNoCC,
  fetchurl,
  uv,
  python312,
  python312Packages,
  makeWrapper,
  zlib,
  cacert,
  version ? "1.3.14",
  # 上游 main 的快照，只为了拿 uv.lock / pyproject.toml（版本 1.3.14 与其锁一致）
  rev ? "c602a2780f4f4dda4a6be46d67abc1cfb1ad420c",
  # 依赖从哪个源下。换源只影响下载速度，不改变产物，所以 outputHash 不用重算
  indexUrl ? "https://pypi.org/simple",
}:

let
  # files.pythonhosted 的路径是内容寻址的，同一个 wheel 的 URL 不会变
  wheel = fetchurl {
    url = "https://files.pythonhosted.org/packages/3c/89/9447696b8088f8cd44ab6abf5405576e071be6a63789d5e8304c27e37cef/maibot-${version}-py3-none-any.whl";
    hash = "sha256-IDSQlqwm57ZA2Jfaglk8h9mNFaCcCqnx+aU5XObZJj8=";
  };

  pyproject = fetchurl {
    url = "https://raw.githubusercontent.com/Mai-with-u/MaiBot/${rev}/pyproject.toml";
    hash = "sha256-HZhYYzjKzkq6/6Jy6DCRN05Oa2PGd1y0MsUYpYMF42I=";
  };

  uvLock = fetchurl {
    url = "https://raw.githubusercontent.com/Mai-with-u/MaiBot/${rev}/uv.lock";
    hash = "sha256-cQaaiaLrhN7TzXKBTeRfcOT9ApcLsK61MgCQBsR0S50=";
  };

  pythonVer = lib.versions.majorMinor python312.version;
  sitePackages = "lib/python${pythonVer}/site-packages";

  # ① uv.lock → requirements.txt（只读本地文件，不联网）
  requirements = stdenvNoCC.mkDerivation {
    pname = "maibot-requirements";
    inherit version;

    dontUnpack = true;
    nativeBuildInputs = [ uv ];

    buildPhase = ''
      runHook preBuild
      export HOME=$TMPDIR
      mkdir project
      cp ${pyproject} project/pyproject.toml
      cp ${uvLock} project/uv.lock
      uv export --frozen --no-dev --no-emit-project --no-hashes \
        --project project -o $out
      runHook postBuild
    '';

    meta.description = "MaiBot 的依赖清单（由上游 uv.lock 导出）";
  };

  # ② 固定输出：把整份清单的 wheel 下下来（纯文件，无 store 引用）
  wheels = stdenvNoCC.mkDerivation {
    pname = "maibot-wheels";
    inherit version;

    dontUnpack = true;
    # pip 只用来下载/编 wheel；--no-build-isolation 下 jieba 的 setuptools 从这两个包来
    nativeBuildInputs = [ python312 python312Packages.pip python312Packages.setuptools python312Packages.wheel ];

    outputHashMode = "recursive";
    outputHash = "sha256-vaypq31XzMHAYkTyvIajIsLHkKeq4K1rWReYwkv/AWw=";

    buildPhase = ''
      runHook preBuild
      export HOME=$TMPDIR
      export PIP_NO_CACHE_DIR=1 PIP_DISABLE_PIP_VERSION_CHECK=1
      export SSL_CERT_FILE=${cacert}/etc/ssl/certs/ca-bundle.crt

      # 清单里每个包都写了确切版本，--no-deps 不会再去解一遍依赖
      pip download --no-deps --no-build-isolation --index-url ${indexUrl} \
        --dest $out -r ${requirements}

      # jieba 只发 sdist，就地编成 wheel（SOURCE_DATE_EPOCH 由 stdenv 设定，zip 时间戳稳定）
      for sdist in $out/*.tar.gz; do
        [ -e "$sdist" ] || continue
        pip wheel --no-deps --no-build-isolation --wheel-dir $out "$sdist"
        rm "$sdist"
      done
      runHook postBuild
    '';

    meta.description = "MaiBot 的依赖 wheel（按上游 uv.lock 下载）";
  };
in
stdenvNoCC.mkDerivation (finalAttrs: {
  pname = "maibot";
  inherit version;

  dontUnpack = true;
  nativeBuildInputs = [ uv python312 makeWrapper ];

  buildPhase = ''
    runHook preBuild
    export HOME=$TMPDIR
    export UV_CACHE_DIR=$TMPDIR/uv-cache
    export UV_PYTHON_DOWNLOADS=never
    export UV_LINK_MODE=copy

    mkdir -p $out/bin $out/${sitePackages}

    # 离线装：只认 ② 里下好的 wheel，一个网都不用连
    # wheel 得换个不带 store hash 前缀的文件名，否则 uv 解析版本号会失败
    cp ${wheel} "$TMPDIR/maibot-${version}-py3-none-any.whl"
    uv pip install --python ${python312}/bin/python3.12 \
      --no-index --find-links ${wheels} \
      --target $out/${sitePackages} --no-progress \
      -r ${requirements} \
      --no-deps "$TMPDIR/maibot-${version}-py3-none-any.whl"

    # uv 会给「直接装的 wheel」塞一份 uv_cache.json，里面是构建时刻的时间戳，纯噪音
    find $out -name uv_cache.json -delete
    find $out -name RECORD -exec sed -i '/uv_cache[.]json/d' {} +

    # 插件市场装插件时会 `python -m pip install`，而 uv 建的 venv 默认不带 pip；
    # 把 nixpkgs 的 pip 直接铺进 site-packages（用它自己 vendor 的依赖，不需要另外装）
    cp -r ${python312Packages.pip}/${sitePackages}/pip $out/${sitePackages}/
    cp -r ${python312Packages.pip}/${sitePackages}/pip-*.dist-info $out/${sitePackages}/

    # ── venv 骨架：解释器 + pyvenv.cfg ───────────────────────────────────
    # CPython 判断「自己在不在 venv 里」看的是 sys.executable 同级的 pyvenv.cfg，
    # 这三个软链少一个 site-packages 就进不了 sys.path。
    ln -s ${python312}/bin/python3.12 $out/bin/python3.12
    ln -s python3.12 $out/bin/python3
    ln -s python3.12 $out/bin/python
    cat > $out/pyvenv.cfg <<EOF
    home = ${python312}/bin
    include-system-site-packages = false
    version = ${python312.version}
    EOF

    # ── 入口脚本：上游 wheel 自带的 console script，shebang 换成本 venv 的 python
    for script in $out/${sitePackages}/bin/*; do
      name=$(basename "$script")
      head -n 1 "$script" | grep -q python || continue
      { echo "#!$out/bin/python"; tail -n +2 "$script"; } > $out/bin/$name
      chmod +x $out/bin/$name
    done

    # numpy / pandas 这些预先编好的 wheel 要动态库：glibc 之外的 libstdc++、zlib
    # 得自己喂进 LD_LIBRARY_PATH（NixOS 上没有 /usr/lib），子进程会继承这个变量
    for script in $out/bin/*; do
      case "$(basename "$script")" in
        python | python3 | python3.12) continue ;;
      esac
      [ -x "$script" ] || continue
      wrapProgram "$script" --prefix LD_LIBRARY_PATH : "${
        lib.makeLibraryPath [ stdenv.cc.cc.lib zlib ]
      }"
    done

    # 依赖快照：排错时不用再猜当时装的是哪一版
    $out/bin/python - > $out/requirements.lock <<'PY'
    from importlib.metadata import distributions
    for dist in sorted(distributions(), key=lambda d: (d.metadata["Name"] or "").lower()):
        print(f"{dist.metadata['Name']}=={dist.version}")
    PY

    runHook postBuild
  '';

  # 上游把只读资源（EULA.md / PRIVACY.md / prompts / locales）打进 wheel 的 src/_resources，
  # 模块用它算协议 hash，绕开非交互终端里的协议确认。
  # 这里必须用 finalPackage 展开成真实 store 路径，placeholder "out" 在 passthru 里不会被替换
  passthru.resources = "${finalAttrs.finalPackage}/${sitePackages}/src/_resources";

  # 模块要在数据目录里拼一个可写 venv（插件装依赖用），这里把解释器和
  # site-packages 的相对路径透出去，省得模块里再猜 python 版本
  passthru.python = python312;
  passthru.sitePackages = sitePackages;

  meta = {
    description = "MaiBot（麦麦）—— 基于大语言模型的可交互 QQ 智能体（程序包安装版）";
    homepage = "https://github.com/Mai-with-u/MaiBot";
    license = lib.licenses.agpl3Only;
    mainProgram = "maibot";
    platforms = [ "x86_64-linux" ];
  };
})
