import { motion, MotionValue, useTransform } from 'framer-motion'

interface Props {
  char: string
  index: number
  total: number
  progress: MotionValue<number>
}

/** 随滚动进度逐字点亮：opacity 0.2 → 1 */
export default function AnimatedLetter({ char, index, total, progress }: Props) {
  const start = index / total
  const opacity = useTransform(progress, [start - 0.1, start + 0.05], [0.2, 1])
  return (
    <motion.span style={{ opacity }} className="whitespace-pre">
      {char}
    </motion.span>
  )
}
