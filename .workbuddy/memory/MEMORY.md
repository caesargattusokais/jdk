# 项目长期记忆 — D:\project\jdk（OpenJDK 28 构建 + 方法调用文档化）

## 文档/动画工作约定（docs 系列）
- 编辑仅作用于 .workbuddy/docs 工作副本；原始 docs/ 保持不动。
- 文档须引用 OpenJDK 28 真实源码 + 行号（本地 D:/project/jdk/src/hotspot 核实），禁止凭记忆。
- 图表：手绘 SVG，配色限蓝 #3b82f6 / 紫 #8b5cf6 / 橙 #f59e0b / 绿 #10b981，节点间距清晰、杜绝文字重叠；禁用 mermaid。
- 文档结构：顶部快速概览 + TOC + 按序编号小节。
- 白话优先：术语密集内容先讲人话（比喻体系），再上源码。五站动画的「白话速览」比喻体系：invokevirtual=喊岗位名 / 解析=查档案记小本 / vtable=员工名册 / 解释器=老实人翻名册+画正字 / JIT 去虚化内联=配速算卡 / nmethod=速算卡 / make_not_entrant=贴停用条。
- 类加载三站比喻体系：双亲委派=从下往上问、从上往下找 / SystemDictionary=交通警察 / ClassLoader::load_class=搬运工 / KlassFactory+ClassFileParser=工匠 / PlaceholderTable=并发占位+循环检测令牌 / 链接三阶段=入职培训 / verify=体检 / rewrite+vtable+itable=接线 / 初始化=上岗宣誓（init_lock=宣誓台，一次只站一个人）/ 失败记错误表=黑账本 / 卸载=公司倒闭整层楼一起清。
- 动画生成管线：gen-cl*.py 用 json.dumps 生成步骤纯数据（d/stage/src/scene/detail/note/face），JS 端 steps.forEach 挂 fn，绕开 f-string 转义；CSS 复用 cl1-css.txt（blu/org/grn/pur/red/dim 类）。
- 验证：动画改动后必须 jsdom 回归（verify 脚本 + 三层断言 desc/stage/src），断言关键词从实际文案抄，不凭印象。

## 工具链坑（重要）
- **Write 工具在 Windows 上写含中文的 .js 文件会编码成 GBK**（UTF-8 读取出现 U+FFFD 乱码、关键词匹配失败）。规避：① 优先用 Edit 修改既有 UTF-8 文件；② 必须 Write 时，写后立即用 `node -e "fs.readFileSync(f,'utf8').includes('中文')"` 验证；③ 若已写成 GBK，用 Python `data.decode('gbk').encode('utf-8')` 转码修复。
- 动画 HTML 内联 JS：d 字段统一用反引号模板字符串（防单引号跨行 SyntaxError）；src( 模板串结尾易漏闭合括号，写后自查函数调用括号成对。
- 验证脚本循环：每迭代先 resetBtn.click() 再点 i 次 next，避免点击位置累积；faceChecks/计数器在步骤数变化时（如插入新 step）须整体 +1。
- stageBox 需 white-space:pre 才能保留多行舞台 ASCII 图（系列五站已统一）。

## OpenJDK 28 Windows 原生构建
- 工具链：VS2022 + Cygwin + boot JDK 27 EA + configure/make；经 IDEA Ant build.xml → bin/idea.sh 触发。
- 历史故障：BASH_ENV/safe-bin 污染、构建锁冲突；按顺序吸收错误反馈继续诊断，不重做已确认步骤。
