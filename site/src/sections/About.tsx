import { useScroll } from 'framer-motion'
import { useRef } from 'react'
import WordsPullUpMultiStyle from '../components/WordsPullUpMultiStyle'
import AnimatedLetter from '../components/AnimatedLetter'

const BODY =
  'AA Switch 住在 Mac 的菜单栏里。点一下，Codex 就在 ChatGPT 账号和你自己的 API 之间切换：历史对话两边都在，登录态自动保留，每次切换前先备份，出了问题自动恢复。额度用完不用停手，思路不用重来，你只管专注在眼前的事上。'

export default function About() {
  const bodyRef = useRef<HTMLParagraphElement>(null)
  const { scrollYProgress } = useScroll({ target: bodyRef, offset: ['start 0.8', 'end 0.2'] })
  const chars = Array.from(BODY)

  return (
    <section id="about" className="bg-black px-4 py-16 sm:px-6 sm:py-24 md:py-32">
      <div className="mx-auto max-w-6xl rounded-2xl bg-[#101010] px-6 py-16 text-center sm:px-12 sm:py-24 md:rounded-[2rem] md:px-20 md:py-32">
        <p className="mb-8 text-[10px] uppercase tracking-[0.2em] text-primary sm:mb-12 sm:text-xs">为什么做 AA Switch</p>

        <h2 className="mx-auto max-w-3xl text-3xl leading-[0.95] sm:text-4xl sm:leading-[0.9] md:text-5xl lg:text-6xl xl:text-7xl">
          <WordsPullUpMultiStyle
            segments={[
              { text: '额度撞顶的那一刻，', className: 'font-normal', breakAfter: true },
              { text: 'keep the flow.', className: 'italic font-serif', keepTogether: true, breakAfter: true },
              { text: '切到自己的 API 继续，会话不断，思路不断。', className: 'font-normal' },
            ]}
          />
        </h2>

        <p
          ref={bodyRef}
          className="mx-auto mt-12 max-w-2xl text-xs leading-relaxed text-[#DEDBC8] sm:mt-16 sm:text-sm md:mt-20 md:text-base"
        >
          {chars.map((c, i) => (
            <AnimatedLetter key={i} char={c} index={i} total={chars.length} progress={scrollYProgress} />
          ))}
        </p>
      </div>
    </section>
  )
}
