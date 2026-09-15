import Hero from './sections/Hero'
import About from './sections/About'
import Features from './sections/Features'

export default function App() {
  return (
    <main className="bg-black">
      <Hero />
      <About />
      <Features />
      <footer className="bg-black px-6 py-8 text-center text-[11px] text-gray-500 sm:text-xs">
        AA Switch · API / Account Switch ·{' '}
        <a href="https://github.com/yhq1998/AA-switch" className="underline-offset-4 hover:text-primary hover:underline">
          GitHub
        </a>
      </footer>
    </main>
  )
}
