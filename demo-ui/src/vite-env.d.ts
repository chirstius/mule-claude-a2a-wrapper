/// <reference types="vite/client" />

interface ImportMetaEnv {
  /** A2A endpoint path, baked at build/embed time from the wrapper config (defaults to /a2a). */
  readonly VITE_A2A_PATH?: string
}
interface ImportMeta {
  readonly env: ImportMetaEnv
}
