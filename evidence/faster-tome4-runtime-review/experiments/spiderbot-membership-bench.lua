local bots, targets = {}, {}
for i=1,10 do bots[i]={x=i%5,y=1} end
for i=1,8 do targets[i]={x=i,y=1} end
local function baseline()
  local hits=0
  for _,t in ipairs(targets) do
    local hit=false
    for _,b in ipairs(bots) do if b.x==t.x and b.y==t.y then hit=true; break end end
    if hit then hits=hits+1 end
  end
  return hits
end
local function indexed()
  local occupied={}
  for _,b in ipairs(bots) do occupied[b.x]=occupied[b.x] or {}; occupied[b.x][b.y]=true end
  local hits=0
  for _,t in ipairs(targets) do if occupied[t.x] and occupied[t.x][t.y] then hits=hits+1 end end
  return hits
end
local function bench(f,n)
  local sum=0
  local started=os.clock()
  for i=1,n do bots[1].x=i%5; sum=sum+f() end
  return os.clock()-started,sum
end
for _,mode in ipairs{'jit','interpreter'} do
 if mode=='interpreter' then jit.off();jit.flush() end
 bench(baseline,10000);bench(indexed,10000)
 for round=1,3 do
  collectgarbage('collect');local a,x=bench(baseline,200000)
  collectgarbage('collect');local b,y=bench(indexed,200000)
  assert(x==y);print(mode,round,a,b,b/a)
 end
end
