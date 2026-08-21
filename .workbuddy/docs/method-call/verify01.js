// verify01.js · 01-linkresolver-animation 回归（18 步版）
const fs=require('fs'), path=require('path');
const {JSDOM}=require('jsdom');
const file=path.join(__dirname,'01-linkresolver-animation.html');
const html=fs.readFileSync(file,'utf8');
let fails=0;
const fail=(m)=>{ fails++; console.error('FAIL:',m); };
const ok=(cond,m)=>{ if(!cond) fail(m); };

// 编码检查
ok(html.includes('按号取人'),'UTF-8 干净（含新步骤中文）');

const dom=new JSDOM(html,{runScripts:'dangerously'});
const d=dom.window.document;
const jsErrs=[];
d.addEventListener('jsdomError',e=>jsErrs.push(e.message));

const pills=d.querySelectorAll('#pills .step-pill');
ok(pills.length===18,'18 pills，实际 '+pills.length);

const btnReset=d.getElementById('btnReset'), btnNext=d.getElementById('btnNext');
const desc=d.getElementById('stepDesc'), stage=d.getElementById('stage'),
      src=d.getElementById('src'), scene=d.getElementById('scene');

function goto(i){ btnReset.click(); for(let j=0;j<i;j++) btnNext.click(); }

// 每步断言
for(let i=0;i<18;i++){
  goto(i);
  const dTxt=desc.textContent, stg=stage.textContent, sc=scene.textContent, srcTxt=src.textContent;
  if(i===0){
    ok(dTxt.includes('白话速览')&&dTxt.includes('第一次喊')&&dTxt.includes('一次解析'),'step0 白话速览关键词');
    ok(sc.includes('白话速览'),'step0 scene 白话速览');
    ok(!dTxt.includes('这一步在干嘛'),'step0 不含人话徽章');
  } else {
    ok(dTxt.includes('这一步在干嘛'),'step'+i+' 含人话徽章');
  }
  // 固定锚点
  if(i===1){
    ok(dTxt.includes('interpreterRuntime.cpp:1063')&&dTxt.includes('interpreterRuntime.cpp:864'),'step1 完整调用链锚点');
  }
  // 新步骤锚点（index 13 = method_at_vtable 拆解）
  if(i===13){
    ok(dTxt.includes('按号取人')&&dTxt.includes('start_of_vtable'),'step13 desc 拆解锚点');
    ok(stg.includes('start_of_vtable()[index].method()')&&stg.includes('vtableEntry'),'step13 stage 实现锚点');
    ok(srcTxt.includes('klass.cpp:1118-1126')&&srcTxt.includes('klassVtable.hpp:182-202')&&srcTxt.includes('Method* _method'),'step13 src 源码锚点');
    ok(sc.includes('场景 12')&&sc.includes('按号取人'),'step13 scene 场景 12');
  }
  if(i===14){
    ok(sc.includes('场景 13')&&sc.includes('method_at_vtable 多态查表'),'step14 scene 顺延 13');
  }
  if(i===17){
    ok(sc.includes('场景 16')&&sc.includes('下一站 klassVtable'),'step17 scene 顺延 16');
  }
}

// 关卡导航
const fc=[[4,2],[12,3],[16,4]];
for(const [i,face] of fc){
  goto(i);
  const on=Array.from({length:4},(_,k)=>d.getElementById('face'+(k+1)).className.includes('on'));
  ok(on[face-1]&&on.filter(x=>x).length===1,'face'+face+' on at step'+i);
}

// 冒烟：reset 后连点到最后一格
btnReset.click();
for(let j=0;j<17;j++) btnNext.click();
ok(desc.textContent.startsWith('18/18'),'冒烟末尾 18/18，实际 '+desc.textContent.split('·')[0].trim());
ok(pills[17].className.includes('active'),'冒烟停 pill 18');

ok(jsErrs.length===0,'零 jsdom 错误，实际 '+jsErrs.length);

console.log(fails===0 ? 'ALL GREEN (18 steps)' : 'FAILS='+fails);
process.exit(fails===0?0:1);
