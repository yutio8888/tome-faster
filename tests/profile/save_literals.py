# GPL-3.0-or-later. Reused read-only serializer parser; no Lua execution.
"""Read ToME serialized literals without evaluating Lua or loading bytecode."""
import re, io, json, hashlib, collections, argparse
from pathlib import Path
from zipfile import ZipFile
from dataclasses import dataclass
@dataclass(frozen=True)
class Ref:
    name: str
@dataclass(frozen=True)
class Opaque:
    name: str
TOKEN = re.compile(r'''\s+|"(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*'|(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][+-]?\d+)?|[a-zA-Z_][a-zA-Z_0-9.]*|.''', re.S)
def string(s):
    s=s[1:-1]
    def sub(m):
        a=m[0][1:]
        if a.isdigit(): return chr(int(a))
        return {'n':'\n','r':'\r','t':'\t','a':'\a','b':'\b','f':'\f','v':'\v'}.get(a,a)
    return re.sub(r'\\(?:\d{1,3}|.)',sub,s,flags=re.S)
class Parser:
    def __init__(self,b):
        self.ts=[m[0] for m in TOKEN.finditer(b.decode('latin1')) if not m[0].isspace()]; self.i=0
    def pop(self):
        t=self.ts[self.i]; self.i+=1; return t
    def eat(self,t):
        got=self.pop()
        if got!=t: raise ValueError((self.i, 'expected',t,'got',repr(got)[:60]))
    def value(self):
        t=self.pop()
        if t=='{':
            v={}; idx=1
            while self.ts[self.i]!='}':
                if self.ts[self.i]=='[':
                    self.eat('['); k=self.value(); self.eat(']'); self.eat('=')
                else: k=idx; idx+=1
                v[k]=self.value()
                if self.ts[self.i] in (',',';'): self.pop()
                elif self.ts[self.i]!='}': raise ValueError(('table delimiter',self.i,self.ts[self.i]))
            self.eat('}'); return v
        if t[0] in ('"',"'"): return string(t)
        if t=='-': return -self.value()
        if t=='true': return True
        if t=='false': return False
        if t=='nil': return None
        if t[0].isdigit() or t[0]=='.': return float(t) if any(x in t for x in '.eE') else int(t)
        if self.i<len(self.ts) and self.ts[self.i]=='(':
            self.eat('('); args=[]
            while self.ts[self.i]!=')':
                args.append(self.value())
                if self.ts[self.i]==',': self.pop()
                elif self.ts[self.i]!=')': raise ValueError(('call delimiter',t,self.i))
            self.eat(')')
            if t=='loadObject': return Ref(args[0])
            return Opaque(t) # Includes serialized loadstring bytecode: never execute it.
        return Opaque(t)
    def parse(self):
        self.eat('d'); self.eat('='); d=self.value()
        if self.ts[self.i]=='setLoaded': self.value()
        while self.ts[self.i]=='d':
            self.eat('d'); self.eat('['); k=self.value(); self.eat(']'); self.eat('='); d[k]=self.value()
        self.eat('return'); self.eat('d')
        if self.i!=len(self.ts): raise ValueError(('trailing',self.i))
        return d

def refs(v):
    todo=[v]
    while todo:
        x=todo.pop()
        if isinstance(x,Ref): yield x.name
        elif isinstance(x,dict):
            todo.extend(x); todo.extend(x.values())
def walk(seeds,data,allow=lambda n:True,blocked=()):
    seen=set(); todo=list(seeds); blocked=set(blocked)
    while todo:
        n=todo.pop()
        if n in seen or n in blocked or n not in data or not allow(n): continue
        seen.add(n); todo.extend(refs(data[n]))
    return seen
