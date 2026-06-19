const fs=require('fs');
function rot(q,v){const{w,x,y,z}=q;const vx=v[0],vy=v[1],vz=v[2];
 const ix=w*vx+y*vz-z*vy, iy=w*vy+z*vx-x*vz, iz=w*vz+x*vy-y*vx, iw=-x*vx-y*vy-z*vz;
 return [ix*w+iw*-x+iy*-z-iz*-y, iy*w+iw*-y+iz*-x-ix*-z, iz*w+iw*-z+ix*-y-iy*-x];}
function circMean(angs){let s=0,c=0;for(const a of angs){s+=Math.sin(a);c+=Math.cos(a);}return Math.atan2(s,c);}
function circStdDeg(angs){let s=0,c=0;for(const a of angs){s+=Math.sin(a);c+=Math.cos(a);}const R=Math.hypot(s,c)/angs.length;return Math.sqrt(-2*Math.log(R))*180/Math.PI;}

function analyze(file,label){
 const lines=fs.readFileSync(file,'utf8').trim().split('\n').map(l=>{try{return JSON.parse(l)}catch{return null}}).filter(Boolean);
 const dm=lines.filter(o=>o.type==='dm'&&o.q&&o.ua&&o.mag);
 // world-frame horizontal user accel + field bearing per sample
 const S=dm.map(o=>{
   const wua=rot(o.q,[o.ua.x,o.ua.y,o.ua.z]);
   const wmag=rot(o.q,[o.mag.x,o.mag.y,o.mag.z]);
   return {t:o.t, ax:wua[0], ay:wua[1], fb:Math.atan2(wmag[1],wmag[0])};
 });
 // window into ~1.2s windows; per window: PCA principal axis of (ax,ay) + sign via integrated velocity
 const rels=[];
 let i=0;
 while(i<S.length){
   let j=i; while(j<S.length && S[j].t - S[i].t < 1.2) j++;
   const w=S.slice(i,j);
   if(w.length>=10){
     const mx=w.reduce((a,b)=>a+b.ax,0)/w.length, my=w.reduce((a,b)=>a+b.ay,0)/w.length;
     let cxx=0,cyy=0,cxy=0;
     for(const s of w){const dx=s.ax-mx,dy=s.ay-my;cxx+=dx*dx;cyy+=dy*dy;cxy+=dx*dy;}
     // principal eigenvector of 2x2 covariance [cxx cxy; cxy cyy]
     const tr=cxx+cyy, det=cxx*cyy-cxy*cxy;
     const l1=tr/2+Math.sqrt(Math.max(0,tr*tr/4-det));
     let ex=cxy, ey=l1-cxx; if(Math.hypot(ex,ey)<1e-9){ex=1;ey=0;}
     let axis=Math.atan2(ey,ex); // undirected travel axis (mod 180)
     // resolve sign via integrated velocity projection on the axis
     let vx=0,vy=0,proj=0;
     for(let k=1;k<w.length;k++){const dt=w[k].t-w[k-1].t; vx+=w[k].ax*dt; vy+=w[k].ay*dt; proj+=(vx*Math.cos(axis)+vy*Math.sin(axis))*dt;}
     if(proj<0) axis+=Math.PI; // flip to direction of net forward velocity
     const fb=circMean(w.map(s=>s.fb));
     let d=axis-fb; while(d>Math.PI)d-=2*Math.PI; while(d<-Math.PI)d+=2*Math.PI;
     rels.push(d);
   }
   i=j;
 }
 const mean=circMean(rels)*180/Math.PI;
 console.log(`${label}: ${rels.length} windows · circMean(travelHeading - fieldBearing)=${mean.toFixed(0)}° · spread=${circStdDeg(rels).toFixed(0)}°`);
 return mean;
}
const f1=analyze(process.argv[2],'FWD survey p1 ');
const f2=analyze(process.argv[3],'FWD survey p2 ');
const r =analyze(process.argv[4],'REVERSE walk  ');
let sep=Math.abs(r-(f1+f2)/2); if(sep>180)sep=360-sep;
console.log(`\nForward mean ~${((f1+f2)/2).toFixed(0)}°, reverse ~${r.toFixed(0)}° → separation ${sep.toFixed(0)}° (want ~180)`);

// ---------------------------------------------------------------------------
// EXPERIMENT RESULT (2026-06-19, LIS traces):
//   FWD survey p1/p2: travelHeading - fieldBearing circMean ~122 deg
//   REVERSE walk:     ~-15 deg  ->  separation 136 deg  (vs 1 deg for the
//   device-compass attitude test). Confirms travel direction IS recoverable
//   from gait/acceleration where device compass is not. The gap from the
//   ideal 180 deg and the wide spread (~90 deg) are from the crude
//   1.2s-window PCA + integrated-velocity sign resolution; a proper per-step
//   PCA-GA with gait-cycle sign resolution (lit. P50 heading error 5.6 deg,
//   PMC6021937) is needed for a clean, usable forward/reverse gate.
//   A temporal-sign-continuity variant made it WORSE (65 deg, forward passes
//   diverged) -- sign resolution must be per-step gait-based, not propagated.
// Usage: node analysis/gait-heading-direction.js <fwd1> <fwd2> <reverse>
