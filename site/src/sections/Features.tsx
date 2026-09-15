import { motion, useInView } from 'framer-motion'
import { ArrowRight, Check, MessagesSquare, ShieldCheck, ToggleRight } from 'lucide-react'
import { useRef, type ReactNode } from 'react'
import WordsPullUpMultiStyle from '../components/WordsPullUpMultiStyle'

const CARD_VIDEO =
  'https://d8j0ntlcm91z4.cloudfront.net/user_38xzZboKViGWJOttwIXH07lWA1P/hf_20260406_133058_0504132a-0cf3-4450-a370-8ea3b05c95d4.mp4'
const README_URL = 'https://github.com/yhq1998/AA-switch#readme'
const ease = [0.22, 1, 0.36, 1] as const

interface Feature {
  number: string
  title: string
  icon: ReactNode
  items: string[]
}

const FEATURES: Feature[] = [
  {
    number: '01',
    title: '一键切换。',
    icon: <ToggleRight className="h-5 w-5 sm:h-6 sm:w-6" />,
    items: ['住在菜单栏，一眼看到当前模式', '账号与 API 互换，只需一次点击', 'Codex 自动退出并重新打开，几秒完成', '开机自启，随时待命'],
  },
  {
    number: '02',
    title: '会话不丢。',
    icon: <MessagesSquare className="h-5 w-5 sm:h-6 sm:w-6" />,
    items: ['历史对话在两种模式下都能继续', 'ChatGPT 登录态自动保留，不用重登', '切换前自动备份，出问题自动恢复'],
  },
  {
    number: '03',
    title: '安全可靠。',
    icon: <ShieldCheck className="h-5 w-5 sm:h-6 sm:w-6" />,
    items: ['API key 只存在 macOS 钥匙串', '已签名公证，拖进应用程序即可用', '完全开源，核心只是一个 bash 脚本'],
  },
]

function Card({ index, children, className = '' }: { index: number; children: ReactNode; className?: string }) {
  const ref = useRef<HTMLDivElement>(null)
  const inView = useInView(ref, { once: true, margin: '-100px' })
  return (
    <motion.div
      ref={ref}
      className={`relative overflow-hidden rounded-2xl ${className}`}
      initial={{ opacity: 0, scale: 0.95 }}
      animate={inView ? { opacity: 1, scale: 1 } : {}}
      transition={{ duration: 0.8, delay: index * 0.15, ease }}
    >
      {children}
    </motion.div>
  )
}

export default function Features() {
  return (
    <section id="features" className="relative min-h-screen bg-black px-4 py-16 sm:px-6 sm:py-24 md:py-32">
      <div className="bg-noise pointer-events-none absolute inset-0 opacity-[0.15]" />
      <div className="relative mx-auto max-w-7xl">
        <h2 className="mx-auto mb-12 max-w-4xl text-center text-xl font-normal sm:mb-16 sm:text-2xl md:mb-20 md:text-3xl lg:text-4xl">
          <WordsPullUpMultiStyle
            segments={[
              { text: '为沉浸式 AI 工作准备的切换器。', className: 'text-[#E1E0CC]', breakAfter: true },
              { text: '一次点击，两种额度，零打断。', className: 'text-gray-500' },
            ]}
          />
        </h2>

        <div className="grid grid-cols-1 gap-3 sm:gap-2 md:grid-cols-2 md:gap-1 lg:h-[480px] lg:grid-cols-4">
          <Card index={0} className="min-h-[320px] bg-[#212121]">
            <div className="brand-backdrop absolute inset-0" />
            <video className="absolute inset-0 h-full w-full object-cover" src={CARD_VIDEO} autoPlay loop muted playsInline />
            <div className="absolute inset-0 bg-gradient-to-t from-black/70 via-transparent to-transparent" />
            <p className="absolute bottom-6 left-6 text-lg font-medium sm:text-xl" style={{ color: '#E1E0CC' }}>
              你的沉浸工作台。
            </p>
          </Card>

          {FEATURES.map((f, i) => (
            <Card key={f.number} index={i + 1} className="flex min-h-[320px] flex-col bg-[#212121] p-6 sm:p-7">
              <div className="flex h-10 w-10 items-center justify-center rounded-lg bg-primary/10 text-primary sm:h-12 sm:w-12">{f.icon}</div>
              <h3 className="mt-6 text-lg font-medium sm:text-xl" style={{ color: '#E1E0CC' }}>
                {f.title} <span className="ml-1 text-xs font-normal text-gray-500 align-top">{f.number}</span>
              </h3>
              <ul className="mt-5 flex flex-col gap-3">
                {f.items.map((item) => (
                  <li key={item} className="flex items-start gap-2.5 text-xs text-gray-400 sm:text-sm">
                    <Check className="mt-0.5 h-4 w-4 shrink-0 text-primary" />
                    <span>{item}</span>
                  </li>
                ))}
              </ul>
              <a
                href={README_URL}
                className="group mt-auto inline-flex w-fit items-center gap-1.5 pt-8 text-xs text-primary sm:text-sm"
              >
                了解更多
                <ArrowRight className="h-4 w-4 -rotate-45 transition-transform group-hover:translate-x-0.5 group-hover:-translate-y-0.5" />
              </a>
            </Card>
          ))}
        </div>
      </div>
    </section>
  )
}
