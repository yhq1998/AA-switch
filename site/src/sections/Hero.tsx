import { useEffect, useState } from 'react'
import { motion } from 'framer-motion'
import { ArrowRight } from 'lucide-react'
import WordsPullUp from '../components/WordsPullUp'

const HERO_VIDEO =
  'https://d8j0ntlcm91z4.cloudfront.net/user_38xzZboKViGWJOttwIXH07lWA1P/hf_20260405_170732_8a9ccda6-5cff-4628-b164-059c500a2b41.mp4'
const DOWNLOAD_URL = import.meta.env.VITE_DOWNLOAD_URL || 'https://github.com/yhq1998/AA-switch/releases/latest'
// 自己托管 dmg 时，同目录的 latest.json（deploy.sh 生成）记录当前版本，显示在下载按钮下面
const LATEST_URL = import.meta.env.VITE_DOWNLOAD_URL ? DOWNLOAD_URL.replace(/[^/]*$/, 'latest.json') : ''
const NAV = [
  { label: '初衷', href: '#about' },
  { label: '功能', href: '#features' },
  { label: '下载', href: DOWNLOAD_URL },
  { label: '开源', href: 'https://github.com/yhq1998/AA-switch' },
  { label: '反馈', href: 'https://github.com/yhq1998/AA-switch/issues' },
]
const ease = [0.16, 1, 0.3, 1] as const
const linkStyle = { color: 'rgba(225, 224, 204, 0.8)' }

export default function Hero() {
  const [latest, setLatest] = useState<{ version: string; date?: string } | null>(null)
  useEffect(() => {
    if (!LATEST_URL) return
    fetch(LATEST_URL, { cache: 'no-store' })
      .then((r) => (r.ok ? r.json() : null))
      .then((j) => j && typeof j.version === 'string' && setLatest(j))
      .catch(() => {})
  }, [])
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
            {NAV.map((item) => (
              <a
                key={item.label}
                href={item.href}
                className="whitespace-nowrap text-[10px] transition-colors sm:text-xs md:text-sm"
                style={linkStyle}
                onMouseEnter={(e) => (e.currentTarget.style.color = '#E1E0CC')}
                onMouseLeave={(e) => (e.currentTarget.style.color = linkStyle.color)}
              >
                {item.label}
              </a>
            ))}
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
              <motion.a
                href={DOWNLOAD_URL}
                className="group inline-flex w-fit items-center gap-2 rounded-full bg-primary py-1.5 pl-5 pr-1.5 text-sm font-medium text-black transition-all hover:gap-3 sm:text-base"
                initial={{ y: 20, opacity: 0 }}
                animate={{ y: 0, opacity: 1 }}
                transition={{ duration: 0.8, delay: 0.7, ease }}
              >
                下载 macOS 版
                <span className="flex h-9 w-9 items-center justify-center rounded-full bg-black transition-transform group-hover:scale-110 sm:h-10 sm:w-10">
                  <ArrowRight className="h-4 w-4 text-primary" />
                </span>
              </motion.a>
              {latest && (
                <motion.p
                  className="text-xs text-primary/50"
                  initial={{ opacity: 0 }}
                  animate={{ opacity: 1 }}
                  transition={{ duration: 0.6, delay: 0.9 }}
                >
                  当前版本 v{latest.version}
                  {latest.date ? ` · ${latest.date} 更新` : ''} · Intel 和 Apple 芯片均支持 · 需要 macOS 13 或更新
                </motion.p>
              )}
            </div>
          </div>
        </div>
      </div>
    </section>
  )
}
