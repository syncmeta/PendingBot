import React, { useEffect, useRef, useState } from 'react';
import { createRoot } from 'react-dom/client';
import { Icon, type IconName } from './icons';
import { initialConversations, people as seedPeople, letter, type Conversation, type Message, type Person, type Tab } from './data';
import './styles.css';

const tabs: {id:Tab; label:string; icon:IconName}[] = [{id:'message', label:'消息', icon:'message'}, {id:'friends', label:'好友', icon:'friends'}, {id:'crew', label:'机组', icon:'crew'}, {id:'envelope', label:'来信', icon:'envelope'}, {id:'me', label:'我', icon:'me'}];
const kindLabel = { private:'私有机器人', public:'公有机器人', human:'人类' };
type Modal = 'new' | 'add' | 'group' | 'settings' | 'search' | 'profile' | null;
function readSaved<T,>(key:string, fallback:T):T { try { const data = localStorage.getItem(key); return data ? JSON.parse(data) as T : fallback; } catch { return fallback; } }
function Avatar({person, size=36}: {person: Pick<Person,'emoji'|'color'>; size?:number}) { return <span className="avatar" style={{width:size,height:size,background:person.color,fontSize:size*.55}}>{person.emoji}</span>; }
function IconButton({icon,label,onClick,children,className=''}: {icon:IconName; label:string; onClick:()=>void; children?:React.ReactNode; className?:string}) { return <button className={`icon-button ${className}`} title={label} aria-label={label} onClick={onClick}><Icon name={icon}/>{children}</button>; }
function App() {
 const [tab,setTab] = useState<Tab>('message');
 const [people,setPeople] = useState<Person[]>(()=>readSaved('pendingbot-demo-people',seedPeople));
 const [conversations,setConversations] = useState<Conversation[]>(()=>readSaved('pendingbot-demo-chats',initialConversations));
 const [selected,setSelected] = useState('mission');
 const [friend,setFriend] = useState<string|null>(null);
 const [letterOpen,setLetterOpen] = useState(false);
 const [section,setSection] = useState('');
 const [mobileDetail,setMobileDetail] = useState(false);
 const [sidebar,setSidebar] = useState(true);
 const [modal,setModal] = useState<Modal>(null);
 const [menu,setMenu] = useState(false);
 const [query,setQuery] = useState('');
 const [filter,setFilter] = useState('all');
 const [sortReverse,setSortReverse] = useState(false);
 const [input,setInput] = useState('');
 const [attachment,setAttachment] = useState('');
 const [actions,setActions] = useState(false);
 const [typing,setTyping] = useState<string|null>(null);
 const [toast,setToast] = useState('');
 const [theme,setTheme] = useState<string>(()=>readSaved('pendingbot-demo-theme','light'));
 const [nickname,setNickname] = useState<string>(()=>readSaved('pendingbot-demo-name','宝堰'));
 const [addName,setAddName] = useState('');
 const [notifications,setNotifications] = useState(true);
 const [searchOpen,setSearchOpen] = useState(false);
 const scrollRef = useRef<HTMLDivElement>(null);
 const fileRef = useRef<HTMLInputElement>(null);
 const timer = useRef<ReturnType<typeof setTimeout>|null>(null);
 const modalRef = useRef<HTMLDivElement>(null);
 const previousFocus = useRef<HTMLElement|null>(null);
 const current = conversations.find(c=>c.id===selected) ?? conversations[0];
 const person = people.find(p=>p.id===current?.personId) ?? people[0];
 const profile = {emoji:'🐌',color:'#e9bfd0'};
 const notify = (text:string) => setToast(text);
 useEffect(()=>{localStorage.setItem('pendingbot-demo-chats',JSON.stringify(conversations));},[conversations]);
 useEffect(()=>{localStorage.setItem('pendingbot-demo-people',JSON.stringify(people));},[people]);
 useEffect(()=>{document.documentElement.dataset.theme=theme;localStorage.setItem('pendingbot-demo-theme',JSON.stringify(theme));},[theme]);
 useEffect(()=>{localStorage.setItem('pendingbot-demo-name',JSON.stringify(nickname));},[nickname]);
 useEffect(()=>{if(!toast)return;const id=setTimeout(()=>setToast(''),3000);return()=>clearTimeout(id);},[toast]);
 useEffect(()=>{scrollRef.current?.scrollTo({top:scrollRef.current.scrollHeight,behavior:'smooth'});},[current?.messages.length,typing,selected]);
 useEffect(()=>()=>{if(timer.current)clearTimeout(timer.current);},[]);
 useEffect(()=>{
  if(!modal)return;previousFocus.current=document.activeElement as HTMLElement;
  const frame=requestAnimationFrame(()=>modalRef.current?.querySelector<HTMLElement>('input,button')?.focus());
  const handle=(event:KeyboardEvent)=>{
   if(event.key==='Escape'){setModal(null);return;}
   if(event.key!=='Tab')return;
   const focusable=modalRef.current?.querySelectorAll<HTMLElement>('button:not(:disabled),input,select,textarea,a[href]');
   if(!focusable?.length)return;
   const first=focusable[0],last=focusable[focusable.length-1];
   if(event.shiftKey&&document.activeElement===first){event.preventDefault();last.focus();}
   else if(!event.shiftKey&&document.activeElement===last){event.preventDefault();first.focus();}
  };document.addEventListener('keydown',handle);return()=>{cancelAnimationFrame(frame);document.removeEventListener('keydown',handle);previousFocus.current?.focus();};
 },[modal]);
 useEffect(()=>{const handle=(event:KeyboardEvent)=>{if((event.metaKey||event.ctrlKey)&&event.key==='k'){event.preventDefault();setModal('search');}if(event.key==='Escape'){setMenu(false);setActions(false);}};document.addEventListener('keydown',handle);return()=>document.removeEventListener('keydown',handle);},[]);
 function changeTab(next:Tab){setTab(next);setMobileDetail(false);setMenu(false);setQuery('');setSearchOpen(false);}
 function selectChat(id:string){setSelected(id);setTab('message');setMobileDetail(true);setInput('');setAttachment('');setActions(false);}
 function newChat(p:Person){const id=crypto.randomUUID();setConversations(prev=>[{id,personId:p.id,title:'新会话',time:'刚刚',messages:[]},...prev]);selectChat(id);setModal(null);}
 function send(){
  if((!input.trim()&&!attachment)||typing)return;
  const chatId=current.id,text=input.trim(),file=attachment;
  const message:Message={id:crypto.randomUUID(),role:'user',text,attachment:file||undefined};
  setConversations(prev=>prev.map(c=>c.id===chatId?{...c,title:c.messages.length?c.title:text||file,time:'刚刚',messages:[...c.messages,message]}:c));
  setInput('');setAttachment('');setActions(false);setTyping(chatId);
  timer.current=setTimeout(()=>{
   const response = file ? `收到文件「${file}」。这是本地演示，文件没有上传。` : /你好|hi|hello/i.test(text) ? '你好，很高兴见到你。今天有什么想一起聊聊的？' : /来信|写信/.test(text) ? '有些话适合慢慢写下来。你可以在左侧的「来信」里，读到关于写信的介绍。' : /模型/.test(text) ? `这个演示中的我是 ${person.name}。客户端可以为不同会话选择模型；这里用预设回复演示聊天交互。` : `我记下了「${text.slice(0,80)}」。\n这是网页版的本地演示回复。我们可以从一个具体的问题开始，一起把想法展开。`;
   setConversations(prev=>prev.map(c=>c.id===chatId?{...c,messages:[...c.messages,{id:crypto.randomUUID(),role:'bot',text:response}]}:c));setTyping(null);timer.current=null;
  },1000);
 }
 function stop(){if(timer.current)clearTimeout(timer.current);timer.current=null;setTyping(null);}
 function addPerson(group=false){if(!addName.trim())return;const id=crypto.randomUUID();const p:Person={id,name:addName.trim(),emoji:group?'👥':'🌱',color:'#d6e7db',model:group?'群聊':'本地好友',kind:'human'};setPeople(prev=>[...prev,p]);setAddName('');setModal(null);if(group)newChat(p);else notify('已添加到本地演示好友');}
 const openDetail=(key:string)=>{setSection(key);setMobileDetail(true);};
 const visibleConversations=conversations.filter(c=>`${c.title} ${people.find(p=>p.id===c.personId)?.name} ${c.messages.map(m=>m.text).join(' ')}`.toLowerCase().includes(query.toLowerCase()));
 const matchedPeople=people.filter(p=>(filter==='all'||p.kind===filter)&&p.name.toLowerCase().includes(query.toLowerCase())).sort((a,b)=>sortReverse?b.name.localeCompare(a.name):a.name.localeCompare(b.name));
 const detailIsChat=tab==='message'&&!!current;
 return <div className={`app ${!sidebar?'sidebar-hidden':''} ${mobileDetail?'mobile-detail':''}`}>
  <aside className="sidebar" aria-label="侧栏">
   <header className="window-toolbar"><div className="traffic-lights" aria-hidden="true"><i/><i/><i/></div><span className="mobile-title">{tabs.find(t=>t.id===tab)?.label}</span><div className="toolbar-actions">
    {tab==='message'&&<IconButton icon="compose" label="新建会话" onClick={()=>setModal('new')}><Icon name="chevron" size={12}/></IconButton>}
    {tab==='friends'&&<IconButton icon="sort" label="切换好友排序" onClick={()=>setSortReverse(!sortReverse)}><Icon name="chevron" size={12}/></IconButton>}
    {(tab==='message'||tab==='friends')&&<div className="menu-anchor"><IconButton icon="plus" label="添加" onClick={()=>setMenu(!menu)}><Icon name="chevron" size={12}/></IconButton>{menu&&<><button className="menu-dismiss" aria-label="关闭添加菜单" onClick={()=>setMenu(false)}/><div className="popup-menu">{([['new','compose','新建会话'],['group','friends','发起群聊'],['add','plus','加好友'],['search','search','搜索消息']] as const).map(([key,icon,label])=><button key={key} onClick={()=>{setModal(key);setMenu(false);}}><Icon name={icon} size={17}/>{label}</button>)}</div></>}</div>}
    <IconButton icon="sidebar" label="收起侧栏" className="collapse" onClick={()=>setSidebar(false)}/>
   </div></header>
   <nav className="tab-rail" aria-label="主导航">{tabs.slice(0,4).map(t=><button key={t.id} title={t.label} aria-label={t.label} aria-current={tab===t.id?'page':undefined} className={tab===t.id?'active':''} onClick={()=>changeTab(t.id)}><Icon name={t.icon} size={21}/><span>{t.label}</span></button>)}<button className={`me-button ${tab==='me'?'active':''}`} title="我" aria-label="我" aria-current={tab==='me'?'page':undefined} onClick={()=>changeTab('me')}><Avatar person={profile} size={26}/><span>我</span></button></nav>
   <div className="list-column">
    {tab==='message'&&<><div className={`list-search ${searchOpen?'expanded':''}`}><Icon name="search" size={15}/><input aria-label="搜索会话" placeholder="搜索" value={query} onChange={e=>setQuery(e.target.value)}/><button onClick={()=>{setSearchOpen(false);setQuery('');}} aria-label="收起搜索"><Icon name="close" size={13}/></button></div><div className="conversation-list">{visibleConversations.map(c=>{const p=people.find(p=>p.id===c.personId)!;return <button key={c.id} className={`conversation-card ${c.id===selected?'selected':''}`} onClick={()=>selectChat(c.id)}><Avatar person={p}/><div className="card-copy"><div className="card-line"><strong>{c.title}</strong><time>{c.time}</time></div><div className="card-line"><span className="preview">{c.messages.at(-1)?.text||'还没有消息'}</span><span className={`tag ${p.kind}`}>{p.name}</span></div></div></button>;})}{!visibleConversations.length&&<div className="empty-list">没有找到会话</div>}</div><button className="search-trigger" onClick={()=>setSearchOpen(true)} aria-label="展开搜索会话"><Icon name="search" size={14}/><span>搜索会话</span><kbd>⌘ K</kbd></button></>}
    {tab==='friends'&&<><button className="profile-row" onClick={()=>setModal('profile')}><Avatar person={profile}/><strong>{nickname}</strong><Icon name="qr" size={20}/></button><div className="filter-pills" aria-label="好友分类">{[['all','全部'],['human','人类'],['private','私有机器人'],['public','公有机器人']].map(([id,label])=><button key={id} className={`${id} ${filter===id?'selected':''}`} aria-pressed={filter===id} onClick={()=>setFilter(id)}>{label}</button>)}</div><div className="friend-list">{matchedPeople.map(p=><button key={p.id} className={`friend-row ${friend===p.id?'selected':''}`} onClick={()=>{setFriend(p.id);setMobileDetail(true);}}><Avatar person={p}/><div><strong className="serif-name">{p.name}</strong><span className="model-tag">{p.model}</span></div><span className={`tag ${p.kind}`}>{kindLabel[p.kind]}</span></button>)}{!matchedPeople.length&&<div className="empty-list">暂无{filter==='human'?'人类好友':'此类好友'}<button className="text-button" onClick={()=>setModal('add')}>加好友</button></div>}</div></>}
    {tab==='crew'&&<div className="construction">待建设</div>}
    {tab==='envelope'&&<button className={`letter-card ${letterOpen?'selected':''}`} onClick={()=>{setLetterOpen(true);setMobileDetail(true);}}><div className="letter-kicker"><img src="/app-icon.png" alt=""/><strong>UNTITLED</strong><time>1分钟前</time></div><h3>{letter.title}</h3><p>{letter.subtitle}</p></button>}
    {tab==='me'&&<><button className="profile-row me-profile" onClick={()=>setModal('profile')}><Avatar person={profile} size={48}/><div><strong>{nickname}</strong><small>PendingBot</small></div></button><div className="account-menu">{([['add','qr','加我为好友的方式'],['wallet','wallet','钱包'],['skills','sparkles','机器人能力扩展'],['settings','settings','设置']] as const).map(([id,icon,label])=><button key={id} className={section===id?'selected':''} onClick={()=>openDetail(id)}><Icon name={icon} size={18}/>{label}<Icon name="chevron" size={14}/></button>)}</div></>}
   </div>
  </aside>
  <main className={`detail ${detailIsChat?'chat-detail':''}`}>
   <div className="detail-navigation"><IconButton icon="back" label="返回列表" className="mobile-back" onClick={()=>setMobileDetail(false)}/>{!sidebar&&<IconButton icon="sidebar" label="展开侧栏" onClick={()=>setSidebar(true)}/>}</div>
   {detailIsChat&&<><header className="conversation-header"><Avatar person={person} size={30}/><div><h1>{current.title}</h1><p>{person.name} · PendingModel</p></div><div className="header-actions"><IconButton icon="compose" label="与此好友新建会话" onClick={()=>newChat(person)}/><IconButton icon="settings" label="会话设置" onClick={()=>setModal('settings')}/></div></header><div className="messages" ref={scrollRef}><div className="message-column"><div className="date-divider">{current.time==='1970年'?'1970年1月1日 10:00':'今天'}</div>{current.messages.map(m=><div key={m.id} className={`message ${m.role}`}>{m.role==='bot'&&<Avatar person={person} size={30}/>}<div className="bubble">{m.attachment&&<div className="attachment-message"><Icon name="file" size={20}/>{m.attachment}</div>}{m.text}</div></div>)}{typing===current.id&&<div className="message bot"><Avatar person={person} size={30}/><div className="bubble typing" aria-label="正在输入"><i/><i/><i/></div></div>}{!current.messages.length&&<div className="chat-empty"><Avatar person={person} size={54}/><h2>{person.name}</h2><p>从一句问候开始。</p></div>}</div></div><div className="composer-wrap">{attachment&&<div className="attachment-chip"><Icon name="file" size={16}/>{attachment}<IconButton icon="close" label="移除附件" onClick={()=>setAttachment('')}/></div>}<div className="composer"><IconButton icon={actions?'close':'plus'} label="消息附件和更多操作" className="attach-button" onClick={()=>setActions(!actions)}/><div className="input-capsule"><textarea aria-label="发消息" placeholder="发消息…" value={input} rows={1} onChange={e=>setInput(e.target.value)} onKeyDown={e=>{if(e.key==='Enter'&&!e.shiftKey&&!e.nativeEvent.isComposing){e.preventDefault();send();}}}/><button className={`send-button ${input.trim()||attachment||typing===current.id?'enabled':''}`} aria-label={typing===current.id?'停止回复':'发送消息'} disabled={typing!==current.id&&(!input.trim()&&!attachment||!!typing)} onClick={()=>typing===current.id?stop():send()}>{typing===current.id?<span className="stop-square"/>:<Icon name="send" size={19}/>}</button></div></div>{actions&&<div className="attachment-actions"><button onClick={()=>{fileRef.current!.accept='image/*';fileRef.current?.click();}}><Icon name="image"/>图片</button><button onClick={()=>{fileRef.current!.accept='';fileRef.current?.click();}}><Icon name="file"/>文件</button><button onClick={()=>{setModal('settings');setActions(false);}}><Icon name="settings"/>会话设置</button></div>}<input ref={fileRef} type="file" hidden onChange={e=>{const f=e.target.files?.[0];if(f)setAttachment(f.name);e.target.value='';}}/></div></>}
   {tab==='friends'&&(friend?<div className="friend-detail">{(()=>{const p=people.find(p=>p.id===friend)!;return <><Avatar person={p} size={80}/><h1 className="serif-name">{p.name}</h1><span className={`tag ${p.kind}`}>{kindLabel[p.kind]}</span><div className="info-card"><span>模型</span><strong>{p.model}</strong></div><button className="primary-button" onClick={()=>{const existing=conversations.find(c=>c.personId===p.id);if(existing)selectChat(existing.id);else newChat(p);}}>发消息</button></>;})()}</div>:<div className="empty-detail"><Icon name="friends" size={48}/></div>)}
   {tab==='envelope'&&(letterOpen?<article className="letter-article"><h1>{letter.title}</h1><p className="letter-subtitle">{letter.subtitle}</p><div className="byline"><img src="/app-icon.png" alt=""/><strong>Untitled</strong><span>于 8月21日 11:38</span></div>{letter.paragraphs.map(p=><p key={p}>{p}</p>)}</article>:<div className="empty-detail"><Icon name="envelope" size={46}/></div>)}
   {tab==='me'&&(section?<div className="settings-page"><h1>{section==='wallet'?'钱包':section==='skills'?'机器人能力扩展':section==='add'?'加我为好友的方式':'设置'}</h1>{section==='settings'?<Settings theme={theme} setTheme={setTheme} notifications={notifications} setNotifications={setNotifications}/>:section==='wallet'?<><div className="balance-card"><span>可用余额</span><strong>$ 0.00</strong><small>本地演示钱包</small></div><h3>交易记录</h3><p className="muted">还没有交易记录</p></>:section==='skills'?<><p className="muted">让机器人拥有更多可能。</p>{['网页搜索','文件阅读','代码沙箱'].map((label,i)=><div className="setting-row" key={label}><Icon name={i===0?'search':i===1?'file':'sparkles'}/><span>{label}</span><span className="tag">{i===2?'待建设':'演示'}</span></div>)}</>:<div className="invite-card"><Avatar person={profile} size={64}/><h2>{nickname}</h2><Icon name="qr" size={112}/><p className="muted">演示名片 · 不可用于实际添加好友</p><button className="secondary-button" onClick={()=>{navigator.clipboard?.writeText(nickname).then(()=>notify('昵称已复制')).catch(()=>notify('浏览器不支持复制，请手动复制昵称'));}}>复制昵称</button></div>}</div>:<div className="empty-detail"><Icon name="me" size={48}/></div>)}
  </main>
  {toast&&<div className="toast" role="status"><Icon name="check" size={16}/>{toast}</div>}
  {modal&&<div className="modal-backdrop" onMouseDown={e=>{if(e.target===e.currentTarget)setModal(null);}}><div className={`modal ${modal==='search'?'search-modal':''}`} role="dialog" aria-modal="true" aria-labelledby="modal-title" ref={modalRef}><header><h2 id="modal-title">{{new:'新建会话',add:'加好友',group:'发起群聊',settings:'会话设置',search:'搜索消息',profile:'个人资料'}[modal]}</h2><IconButton icon="close" label="关闭弹窗" onClick={()=>setModal(null)}/></header>
   {modal==='new'&&<div className="new-chat-list">{people.map(p=><button key={p.id} onClick={()=>newChat(p)}><Avatar person={p}/><strong>{p.name}</strong><span className={`tag ${p.kind}`}>{kindLabel[p.kind]}</span></button>)}</div>}
   {(modal==='add'||modal==='group')&&<form onSubmit={e=>{e.preventDefault();addPerson(modal==='group');}}><p className="muted">{modal==='group'?'为本地演示群聊起个名字。':'输入昵称，添加一个本地演示好友。'}</p><label className="form-label">{modal==='group'?'群聊名称':'好友昵称'}<input required maxLength={40} value={addName} onChange={e=>setAddName(e.target.value)} placeholder={modal==='group'?'新的群聊':'昵称'}/></label><button type="submit" className="primary-button" disabled={!addName.trim()}>{modal==='group'?'创建群聊':'添加好友'}</button></form>}
   {modal==='search'&&<><div className="search-field"><Icon name="search" size={18}/><input aria-label="搜索消息内容" placeholder="搜索会话、好友或消息内容" value={query} onChange={e=>setQuery(e.target.value)}/></div><div className="search-results">{visibleConversations.map(c=><button key={c.id} onClick={()=>{selectChat(c.id);setModal(null);setQuery('');}}><strong>{c.title}</strong><span>{c.messages.find(m=>m.text.includes(query))?.text||'还没有消息'}</span></button>)}{!visibleConversations.length&&<p className="muted">没有找到相关消息</p>}</div><p className="shortcut-hint">⌘ / Ctrl K 打开搜索 · Esc 关闭</p></>}
   {modal==='settings'&&<><div className="conversation-person"><Avatar person={person} size={48}/><strong>{person.name}</strong><span className={`tag ${person.kind}`}>{kindLabel[person.kind]}</span></div><label className="form-label">会话名称<input value={current.title} maxLength={100} onChange={e=>setConversations(prev=>prev.map(c=>c.id===selected?{...c,title:e.target.value}:c))}/></label><div className="setting-row"><span>当前模型</span><span className="model-tag">{person.model}</span></div><div className="setting-row"><span>来信</span><button className="text-button" onClick={()=>{changeTab('envelope');setLetterOpen(true);setMobileDetail(true);setModal(null);}}>阅读来信</button></div><p className="muted small">此演示仅在当前浏览器保存对话，回复为本地预设内容。</p></>}
   {modal==='profile'&&<><div className="profile-editor"><Avatar person={profile} size={72}/></div><label className="form-label">昵称<input value={nickname} maxLength={30} onChange={e=>setNickname(e.target.value)}/></label><button className="primary-button" onClick={()=>setModal(null)}>完成</button></>}
  </div></div>}
 </div>;
}
function Settings({theme,setTheme,notifications,setNotifications}: {theme:string;setTheme:(v:string)=>void;notifications:boolean;setNotifications:(v:boolean)=>void}) {return <><div className="settings-group"><div className="setting-row"><span>外观</span><div className="segmented">{[['light','sun','浅色'],['dark','moon','深色']].map(([value,icon,label])=><button key={value} aria-pressed={theme===value} className={theme===value?'active':''} onClick={()=>setTheme(value)}><Icon name={icon as IconName} size={15}/>{label}</button>)}</div></div><div className="setting-row"><span>消息提醒</span><button role="switch" aria-checked={notifications} aria-label="消息提醒（演示）" className={`switch ${notifications?'on':''}`} onClick={()=>setNotifications(!notifications)}><i/></button></div></div><p className="muted small">提醒开关仅演示外观，不申请系统通知权限。</p><div className="about-app"><img src="/app-icon.png" alt="PendingBot"/><h3>PendingBot</h3><p>React + TypeScript 网页演示</p></div></>;}

createRoot(document.getElementById('root')!).render(<React.StrictMode><App/></React.StrictMode>);
