const V='didi-v8';
const SHELL=['./','index.html','manifest.json','icon-192.png','icon-512.png'];
// 파일 하나가 없어도 설치가 실패하지 않도록 하나씩 저장
self.addEventListener('install',e=>{e.waitUntil(caches.open(V).then(c=>Promise.all(SHELL.map(u=>c.add(u).catch(()=>{})))).then(()=>self.skipWaiting()))});
self.addEventListener('activate',e=>{e.waitUntil(caches.keys().then(k=>Promise.all(k.filter(x=>x!==V).map(x=>caches.delete(x)))).then(()=>self.clients.claim()))});
// 같은 주소의 파일만 처리 (Supabase/이미지 요청은 건드리지 않음). 네트워크 우선, 오프라인이면 저장본.
self.addEventListener('fetch',e=>{
  const r=e.request,u=new URL(r.url);
  if(r.method!=='GET'||u.origin!==location.origin)return;
  e.respondWith(fetch(r).then(res=>{if(res.ok){const cp=res.clone();caches.open(V).then(c=>c.put(r,cp))}return res})
    .catch(()=>caches.match(r).then(m=>m||caches.match('index.html'))));
});
