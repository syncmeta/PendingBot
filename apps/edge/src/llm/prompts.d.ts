// Wrangler's text rule lets us `import` .md files as strings. TS doesn't know
// about the rule by default, so this declaration teaches the compiler.
declare module '*.md' {
  const content: string;
  export default content;
}
