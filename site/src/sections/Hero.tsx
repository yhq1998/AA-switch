import { useEffect, useState } from 'react'
import { motion } from 'framer-motion'
import { ArrowRight, ChevronDown } from 'lucide-react'
import WordsPullUp from '../components/WordsPullUp'

const HERO_VIDEO =
  'https://d8j0ntlcm91z4.cloudfront.net/user_38xzZboKViGWJOttwIXH07lWA1P/hf_20260405_170732_8a9ccda6-5cff-4628-b164-059c500a2b41.mp4'
const DOWNLOAD_URL = import.meta.env.VITE_DOWNLOAD_URL || 'https://github.com/yhq1998/AA-switch/releases/latest'
// 自己托管时保存下来的文件名固定叫“AA Switch.dmg”（同源链接 download 属性才生效，指向 GitHub 时忽略）
const DOWNLOAD_NAME = import.meta.env.VITE_DOWNLOAD_URL ? 'AA Switch.dmg' : undefined
// 自己托管安装包时，同目录的 latest.json（deploy.sh 生成）记录两个平台的当前版本：顶层是 macOS 版，windows 段是 Windows 版
const LATEST_URL = import.meta.env.VITE_DOWNLOAD_URL ? DOWNLOAD_URL.replace(/[^/]*$/, 'latest.json') : ''
type Release = { version: string; date?: string; url?: string }
type Latest = Release & { windows?: Release }
type Download = { os: 'mac' | 'windows'; name: string; label: string; href: string; filename?: string; release?: Release; note: string }
const ease = [0.16, 1, 0.3, 1] as const
const linkStyle = { color: 'rgba(225, 224, 204, 0.8)' }

export default function Hero() {
  const [latest, setLatest] = useState<Latest | null>(null)
  const [onWindows, setOnWindows] = useState(false)
  // 地址加 ?os=windows / ?os=mac 可以指定平台（预览另一个平台的样子，或者替别的电脑下载）
  useEffect(() => {
    const forced = new URLSearchParams(location.search).get('os')
    setOnWindows(forced ? forced === 'windows' : /Windows/i.test(navigator.userAgent))
  }, [])
  useEffect(() => {
    if (!LATEST_URL) return
    fetch(LATEST_URL, { cache: 'no-store' })
      .then((r) => (r.ok ? r.json() : null))
      .then((j) => j && typeof j.version === 'string' && setLatest(j))
      .catch(() => {})
  }, [])
  const [menuOpen, setMenuOpen] = useState(false)   // 顶部“下载”的下拉框：鼠标悬停展开，触屏上点一下展开
  const mac: Download = {
    os: 'mac', name: 'macOS 版', label: '下载 macOS 版', href: DOWNLOAD_URL, filename: DOWNLOAD_NAME, release: latest ?? undefined,
    note: 'Intel 和 Apple 芯片均支持 · 需要 macOS 13 或更新',
  }
  // Windows 版发布过（latest.json 里有 windows 段）才出现。两个平台的按钮并排，访客自己的系统排在前面
  const win: Download | null = latest?.windows?.url
    ? { os: 'windows', name: 'Windows 版', label: '下载 Windows 版', href: latest.windows.url, filename: 'AA Switch.exe', release: latest.windows,
        note: 'Windows 10 / 11（64 位）· 免安装，双击运行 · 若被 SmartScreen 拦下，点“更多信息 → 仍要运行”' }
    : null
  const downloads: Download[] = win ? (onWindows ? [win, mac] : [mac, win]) : [mac]
  // menu 为真的那一项是“下载”：有两个平台时展开成下拉框，只有一个平台时就是普通链接
  const NAV: { label: string; href: string; download?: string; menu?: boolean }[] = [
    { label: '初衷', href: '#about' },
    { label: '功能', href: '#features' },
    { label: '下载', href: downloads[0].href, download: downloads[0].filename, menu: downloads.length > 1 },
    { label: '开源', href: 'https://github.com/yhq1998/AA-switch' },
    { label: '反馈', href: 'https://github.com/yhq1998/AA-switch/issues' },
  ]
  const navLinkClass = 'whitespace-nowrap text-[10px] transition-colors sm:text-xs md:text-sm'
  return (
    <section className="h-screen bg-black p-4 md:p-6">
      <div className="relative h-full w-full overflow-hidden rounded-2xl md:rounded-[2rem]">
        {/* 视频加载前的品牌色底，避免黑屏 */}
        <div className="brand-backdrop absolute inset-0" />
        <video className="absolute inset-0 h-full w-full object-cover" src={HERO_VIDEO} autoPlay loop muted playsInline />
        <div className="noise-overlay pointer-events-none absolute inset-0 opacity-[0.7] mix-blend-overlay" />
        <div className="pointer-events-none absolute inset-0 bg-gradient-to-b from-black/30 via-transparent to-black/60" />

        {/* 顶部导航 */}
        <nav className="absolute left-1/2 top-0 -translate-x-1/2">
          <div className="flex items-center gap-3 rounded-b-2xl bg-black px-4 py-2 sm:gap-6 md:gap-12 md:rounded-b-3xl md:px-8 lg:gap-14">
            {NAV.map((item) =>
              item.menu ? (
                <div
                  key={item.label}
                  className="relative"
                  onMouseEnter={() => setMenuOpen(true)}
                  onMouseLeave={() => setMenuOpen(false)}
                  onBlur={(e) => !e.currentTarget.contains(e.relatedTarget) && setMenuOpen(false)}
                  onKeyDown={(e) => e.key === 'Escape' && setMenuOpen(false)}
                >
                  <button
                    type="button"
                    aria-haspopup="menu"
                    aria-expanded={menuOpen}
                    onClick={() => setMenuOpen((o) => !o)}
                    className={`${navLinkClass} flex items-center gap-1`}
                    style={{ color: menuOpen ? '#E1E0CC' : linkStyle.color }}
                  >
                    {item.label}
                    <ChevronDown className={`h-3 w-3 transition-transform ${menuOpen ? 'rotate-180' : ''}`} />
                  </button>
                  {menuOpen && (
                    // 外层的 pt 把按钮和面板之间的空隙也算进悬停范围，鼠标移下去时不会中途收起
                    <div className="absolute left-1/2 top-full z-20 -translate-x-1/2 pt-3" role="menu">
                      <motion.div
                        className="flex flex-col gap-0.5 rounded-2xl border border-white/10 bg-black p-1.5 shadow-xl"
                        initial={{ opacity: 0, y: -6 }}
                        animate={{ opacity: 1, y: 0 }}
                        transition={{ duration: 0.18, ease }}
                      >
                        {downloads.map((d) => (
                          <a
                            key={d.os}
                            role="menuitem"
                            href={d.href}
                            download={d.filename}
                            onClick={() => setMenuOpen(false)}
                            className="flex items-baseline justify-between gap-6 whitespace-nowrap rounded-xl px-3 py-2 text-xs text-primary/80 transition-colors hover:bg-white/10 hover:text-primary md:text-sm"
                          >
                            {d.name}
                            {d.release && <span className="text-[10px] text-primary/40 md:text-xs">v{d.release.version}</span>}
                          </a>
                        ))}
                      </motion.div>
                    </div>
                  )}
                </div>
              ) : (
                <a
                  key={item.label}
                  href={item.href}
                  download={item.download}
                  className={navLinkClass}
                  style={linkStyle}
                  onMouseEnter={(e) => (e.currentTarget.style.color = '#E1E0CC')}
                  onMouseLeave={(e) => (e.currentTarget.style.color = linkStyle.color)}
                >
                  {item.label}
                </a>
              ),
            )}
          </div>
        </nav>

        {/* 左上角小标识 */}
        <motion.div
          className="absolute left-5 top-5 flex items-center gap-2 sm:left-8 sm:top-7"
          initial={{ opacity: 0 }}
          animate={{ opacity: 1 }}
          transition={{ delay: 0.3, duration: 0.8 }}
        >
          <img src="/aa-switch.svg" alt="" className="h-7 w-7 sm:h-8 sm:w-8" />
          <span className="text-xs font-bold tracking-wide text-primary/80 sm:text-sm">AA Switch</span>
        </motion.div>

        {/* 底部内容 */}
        <div className="absolute bottom-0 left-0 right-0 px-5 pb-6 sm:px-8 sm:pb-8 md:px-10 md:pb-10">
          <div className="grid grid-cols-12 items-end gap-x-6 gap-y-6">
            <h1
              className="col-span-12 text-[18vw] font-medium leading-[0.85] tracking-[-0.07em] sm:text-[17vw] md:col-span-8 md:text-[15vw] lg:text-[14vw] xl:text-[13.5vw]"
              style={{ color: '#E1E0CC' }}
            >
              <WordsPullUp text="AA Switch" showAsterisk />
            </h1>
            <div className="col-span-12 flex flex-col gap-5 md:col-span-4 md:pb-3">
              <motion.p
                className="max-w-sm text-xs text-primary/70 sm:text-sm md:text-base"
                style={{ lineHeight: 1.2 }}
                initial={{ y: 20, opacity: 0 }}
                animate={{ y: 0, opacity: 1 }}
                transition={{ duration: 0.8, delay: 0.5, ease }}
              >
                不再为撞顶烦恼。ChatGPT 账号和你自己的 API 随时切换，历史会话一个不丢，登录态自动保留。把注意力还给创作，而不是额度。
              </motion.p>
              <div className="flex flex-wrap gap-3">
                {downloads.map((d, i) => (
                  <motion.a
                    key={d.os}
                    href={d.href}
                    download={d.filename}
                    className="group inline-flex w-fit items-center gap-2 whitespace-nowrap rounded-full bg-primary py-1.5 pl-5 pr-1.5 text-sm font-medium text-black transition-all hover:gap-3 sm:text-base"
                    initial={{ y: 20, opacity: 0 }}
                    animate={{ y: 0, opacity: 1 }}
                    transition={{ duration: 0.8, delay: 0.7 + i * 0.1, ease }}
                  >
                    {d.label}
                    <span className="flex h-9 w-9 items-center justify-center rounded-full bg-black transition-transform group-hover:scale-110 sm:h-10 sm:w-10">
                      <ArrowRight className="h-4 w-4 text-primary" />
                    </span>
                  </motion.a>
                ))}
              </div>
              {latest && (
                <motion.p
                  className="flex flex-col gap-1 text-xs text-primary/50"
                  initial={{ opacity: 0 }}
                  animate={{ opacity: 1 }}
                  transition={{ duration: 0.6, delay: 0.9 }}
                >
                  {downloads.map((d) => d.release && (
                    <span key={d.os}>
                      {d.os === 'windows' ? 'Windows' : 'macOS'} v{d.release.version}
                      {d.release.date ? ` · ${d.release.date} 更新` : ''} · {d.note}
                    </span>
                  ))}
                </motion.p>
              )}
            </div>
          </div>
        </div>
      </div>
    </section>
  )
}
