import type { CSSProperties } from 'react';
export type IconName = 'message' | 'friends' | 'crew' | 'envelope' | 'me' | 'plus' | 'compose' | 'sidebar' | 'settings' | 'chevron' | 'back' | 'send' | 'close' | 'search' | 'file' | 'image' | 'phone' | 'wallet' | 'qr' | 'sparkles' | 'check' | 'sun' | 'moon' | 'sort';
const paths: Record<IconName, React.ReactNode> = {
 message: <path d="M5 4h14a2 2 0 0 1 2 2v10a2 2 0 0 1-2 2h-8l-5 4v-4H5a2 2 0 0 1-2-2V6a2 2 0 0 1 2-2Z"/>,
 friends: <><circle cx="8" cy="7" r="3"/><circle cx="17" cy="6" r="3"/><path d="M1 20v-1a6 6 0 0 1 12 0v1Zm12 0h10v-2a6 6 0 0 0-9-5"/></>,
 crew: <><path d="m3 4 2 4 2-4Z"/><path d="m11 5 9 1M11 11l7 1M11 18l7 1" strokeWidth="3"/><circle cx="5" cy="16" r="1"/></>,
 envelope: <><path d="m3 9 9-7 9 7v12H3Z"/><path d="m3 9 9 8 9-8M3 21l7-6m11 6-7-6"/></>,
 me: <><circle cx="12" cy="12" r="10"/><circle cx="12" cy="9" r="3"/><path d="M5 19a7 7 0 0 1 14 0"/></>,
 plus: <path d="M12 3v18M3 12h18"/>, compose: <><path d="M20 12v7a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V6a2 2 0 0 1 2-2h8M10 14l1-5L20 1l3 3-9 9Z"/></>,
 sidebar: <><rect x="2" y="3" width="20" height="18" rx="3"/><path d="M8 3v18M5 7h0M5 10h0"/></>,
 settings: <><path d="m10 2-.8 3-2 .9-2.8-.8-2 3.5 2 2.2v2.4l-2 2.2 2 3.5 2.8-.8 2 .9.8 3h4l.8-3 2-.9 2.8.8 2-3.5-2-2.2v-2.4l2-2.2-2-3.5-2.8.8-2-.9L14 2Z"/><circle cx="12" cy="12" r="3"/></>,
 chevron: <path d="m8 10 4 4 4-4"/>, back: <path d="m15 4-8 8 8 8"/>, send: <path d="M12 21V3m-7 7 7-7 7 7"/>, close: <path d="m5 5 14 14M5 19 19 5"/>, search: <><circle cx="10" cy="10" r="7"/><path d="m15 15 6 6"/></>,
 file: <><path d="M5 2h9l5 5v15H5Z M14 2v6h5"/><path d="M8 13h8M8 17h6"/></>, image: <><rect x="2" y="3" width="20" height="18" rx="3"/><circle cx="8" cy="8" r="2"/><path d="m2 18 6-5 4 3 5-6 5 7"/></>,
 phone: <path d="M5 2 2 5c0 8 9 17 17 17l3-3-5-5-3 2-6-6 2-3Z"/>, wallet: <><rect x="2" y="5" width="20" height="16" rx="3"/><path d="M3 5V3h16v2M16 11h6v5h-6Z"/></>,
 qr: <><path d="M2 2h7v7H2ZM15 2h7v7h-7ZM2 15h7v7H2ZM15 15h3v3h-3ZM21 15v7h-6M5 5h1M18 5h1M5 18h1"/></>, sparkles: <><path d="m12 3 3 6 6 3-6 3-3 6-3-6-6-3 6-3Z M21 1v4M19 3h4"/></>, check: <path d="m4 12 5 5L21 5"/>, sun: <><circle cx="12" cy="12" r="4"/><path d="M12 1v2m0 18v2M1 12h2m18 0h2M4 4l2 2m12 12 2 2M4 20l2-2M18 6l2-2"/></>, moon: <path d="M21 14A10 10 0 0 1 10 3a10 10 0 1 0 11 11Z"/>, sort: <path d="M6 21V3m-4 4 4-4 4 4M17 3v18m-4-4 4 4 4-4"/>
};
export function Icon({name, size=20, style}: {name: IconName; size?:number; style?:CSSProperties}) { return <svg width={size} height={size} viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true" style={style}>{paths[name]}</svg>; }
