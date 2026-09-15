import { motion, useInView } from 'framer-motion'
import { useRef } from 'react'

export interface Segment {
  text: string
  className?: string
  /** 段落结束后强制换行 */
  breakAfter?: boolean
  /** 整段作为一个整体入场、不在中间换行（适合短的英文点缀句） */
  keepTogether?: boolean
}

interface Props {
  segments: Segment[]
  className?: string
  justify?: 'center' | 'start'
}

const ease = [0.16, 1, 0.3, 1] as const
// 空白 | 单个中日韩字符或全角标点 | 其他连续非空白
const TOKEN = /\s+|[㐀-鿿　-〿＀-￯]|[^\s㐀-鿿　-〿＀-￯]+/g

type Token = { text: string; className?: string; br?: boolean; space?: boolean }

/** 把多段不同样式的文本拆成单词逐词上滑入场；中文按字拆分，空格原样保留 */
export default function WordsPullUpMultiStyle({ segments, className = '', justify = 'center' }: Props) {
  const ref = useRef<HTMLSpanElement>(null)
  const inView = useInView(ref, { once: true, margin: '-40px' })

  const tokens: Token[] = []
  segments.forEach((seg) => {
    const parts = seg.keepTogether ? [seg.text] : seg.text.match(TOKEN) ?? []
    parts.forEach((p) => {
      if (/^\s+$/.test(p)) tokens.push({ text: p, space: true })
      else tokens.push({ text: p, className: seg.className })
    })
    if (seg.breakAfter) tokens.push({ text: '', br: true })
  })
  const visible = tokens.filter((t) => !t.space && !t.br).length
  const step = Math.min(0.08, 1.0 / Math.max(visible, 1)) // 整体错开不超过 1 秒，中文长句也不会拖太久

  let order = 0
  return (
    <span
      ref={ref}
      className={`inline-flex flex-wrap items-baseline ${justify === 'center' ? 'justify-center' : 'justify-start'} ${className}`}
    >
      {tokens.map((t, i) => {
        if (t.br) return <span key={i} className="h-0 basis-full" />
        if (t.space) return <span key={i} className="inline-block w-[0.25em]" />
        const delay = order++ * step
        return (
          <span key={i} className="inline-block overflow-hidden">
            <motion.span
              className={`inline-block whitespace-nowrap ${t.className ?? ''}`}
              initial={{ y: 20, opacity: 0 }}
              animate={inView ? { y: 0, opacity: 1 } : {}}
              transition={{ duration: 0.6, delay, ease }}
            >
              {t.text}
            </motion.span>
          </span>
        )
      })}
    </span>
  )
}
