import { motion, useInView } from 'framer-motion'
import { useRef } from 'react'

interface Props {
  text: string
  className?: string
  /** 在最后一个词的末尾加一个上标星号 */
  showAsterisk?: boolean
  delay?: number
}

const ease = [0.16, 1, 0.3, 1] as const

export default function WordsPullUp({ text, className = '', showAsterisk = false, delay = 0 }: Props) {
  const ref = useRef<HTMLSpanElement>(null)
  const inView = useInView(ref, { once: true })
  const words = text.split(' ')

  return (
    <span ref={ref} className={`inline-flex flex-wrap ${className}`}>
      {words.map((word, i) => {
        const last = i === words.length - 1
        return (
          <span key={i} className={`mr-[0.25em] inline-block overflow-hidden last:mr-0 ${showAsterisk && last ? 'pr-[0.4em]' : ''}`}>
            <motion.span
              className="relative inline-block"
              initial={{ y: 20, opacity: 0 }}
              animate={inView ? { y: 0, opacity: 1 } : {}}
              transition={{ duration: 0.6, delay: delay + i * 0.08, ease }}
            >
              {word}
              {showAsterisk && last && (
                <span className="absolute top-[0.65em] -right-[0.3em] text-[0.31em] font-normal">*</span>
              )}
            </motion.span>
          </span>
        )
      })}
    </span>
  )
}
