# ============================================================
# FORTUNE TECH + FORTUNEFLIX + CLOUDINARY - ALL IN ONE FILE
# Run: pip install fastapi uvicorn python-multipart requests cloudinary
# ============================================================

from fastapi import FastAPI, UploadFile, File, Form
from fastapi.responses import FileResponse, HTMLResponse
from fastapi.middleware.cors import CORSMiddleware
from fastapi.staticfiles import StaticFiles
import json, os, shutil, time, requests

# --- CLOUDINARY ---
try:
    import cloudinary
    import cloudinary.uploader
    import cloudinary.api
    HAS_CLOUDINARY = True
except:
    HAS_CLOUDINARY = False

app = FastAPI()
app.add_middleware(CORSMiddleware, allow_origins=["*"], allow_methods=["*"], allow_headers=["*"])

# ============ 👇 CHANGE ONLY THESE LINES 👇 ============
WHATSAPP_NUMBER = "2348000000000"  # Your WhatsApp e.g 2348031234567
PAYSTACK_SECRET = "sk_test_YOUR_SECRET_KEY_HERE"
PAYSTACK_PUBLIC = "pk_test_YOUR_PUBLIC_KEY_HERE"

# CLOUDINARY - Get from cloudinary.com Dashboard
CLOUDINARY_CLOUD_NAME = "YOUR_CLOUD_NAME_HERE"  # e.g "dabc123"
CLOUDINARY_API_KEY = "YOUR_API_KEY_HERE"        # e.g "123456789"
CLOUDINARY_API_SECRET = "YOUR_API_SECRET_HERE"  # e.g "AbcXyz..."

# If you put your real keys, e go use Cloudinary. If not, e go use local folder.
USE_CLOUDINARY = CLOUDINARY_CLOUD_NAME != "YOUR_CLOUD_NAME_HERE" and HAS_CLOUDINARY

if USE_CLOUDINARY:
    cloudinary.config(
        cloud_name=CLOUDINARY_CLOUD_NAME,
        api_key=CLOUDINARY_API_KEY,
        api_secret=CLOUDINARY_API_SECRET,
        secure=True
    )
    print("✅ Cloudinary Connected - Films go save forever")
else:
    print("⚠️ Using Local Storage - Put Cloudinary keys to save forever")
# =========================================================

os.makedirs("videos", exist_ok=True)
os.makedirs("posters", exist_ok=True)
if not os.path.exists("films.json"): open("films.json","w").write("[]")
if not os.path.exists("users.json"): open("users.json","w").write("[]")
if os.path.exists("videos"):
    app.mount("/videos", StaticFiles(directory="videos"), name="videos")
if os.path.exists("posters"):
    app.mount("/posters", StaticFiles(directory="posters"), name="posters")

def load_json(n):
    try:
        with open(n) as f: return json.load(f)
    except: return []
def save_json(n,d):
    with open(n,"w") as f: json.dump(d,f,indent=2)

def upload_to_cloudinary(file_bytes, filename, is_video=True):
    """Upload to Cloudinary, return secure URL"""
    import tempfile
    with tempfile.NamedTemporaryFile(delete=False, suffix=os.path.splitext(filename)[1]) as tmp:
        tmp.write(file_bytes)
        tmp_path = tmp.name
    try:
        if is_video:
            # For video, use large upload
            res = cloudinary.uploader.upload_large(
                tmp_path,
                resource_type="video",
                folder="fortuneflix/videos",
                chunk_size=6000000
            )
        else:
            res = cloudinary.uploader.upload(
                tmp_path,
                resource_type="image",
                folder="fortuneflix/posters"
            )
        os.unlink(tmp_path)
        return res["secure_url"]
    except Exception as e:
        print(f"Cloudinary error: {e}")
        os.unlink(tmp_path)
        return None

# ================= AUTH =================
@app.post("/api/signup")
def signup(email: str = Form(...), password: str = Form(...)):
    users = load_json("users.json")
    if any(u["email"]==email for u in users):
        return {"success": False, "msg": "Email don exist"}
    users.append({"email":email,"password":password,"role":"user","premium_until":0})
    save_json("users.json", users)
    return {"success": True, "msg": "Account created! Login now"}

@app.post("/api/login")
def login(email: str = Form(...), password: str = Form(...)):
    users = load_json("users.json")
    if email=="admin@fortune.com" and password=="admin123":
        return {"success": True, "role":"admin", "email":email}
    for u in users:
        if u["email"]==email and u["password"]==password:
            return {"success": True, "role":"user", "email":email}
    return {"success": False, "msg": "Wrong email or password"}

# ================= FILMS =================
@app.get("/api/films")
def get_films(category: str = ""):
    films = load_json("films.json")
    if category and category!="All":
        films = [f for f in films if f["category"]==category]
    return films

@app.get("/api/categories")
def get_categories():
    films = load_json("films.json")
    cats = list(set([f["category"] for f in films]))
    return ["All"] + cats

@app.post("/api/upload")
async def upload(title: str = Form(...), desc: str = Form(...), category: str = Form(...),
                 is_premium: str = Form("false"),
                 video: UploadFile = File(...), poster: UploadFile = File(None)):
    films = load_json("films.json")
    new_id = str(len(films)+1)
    video_bytes = await video.read()
    poster_bytes = await poster.read() if poster else None

    # --- CLOUDINARY OR LOCAL ---
    if USE_CLOUDINARY:
        video_url = upload_to_cloudinary(video_bytes, video.filename, is_video=True)
        if not video_url:
            return {"success": False, "msg": "Cloudinary upload failed - check keys"}
        poster_url = f"https://picsum.photos/300/450?random={new_id}"
        if poster_bytes:
            p_url = upload_to_cloudinary(poster_bytes, poster.filename, is_video=False)
            if p_url: poster_url = p_url
        # For Cloudinary, we save full URL as file
        films.append({"id":new_id,"title":title,"desc":desc,"category":category,"is_premium":is_premium=="true","poster":poster_url,"file":video_url,"is_cloudinary":True})
    else:
        # Local fallback
        video_path = f"videos/{new_id}_{video.filename}"
        with open(video_path,"wb") as f: f.write(video_bytes)
        poster_url = f"https://picsum.photos/300/450?random={new_id}"
        if poster_bytes:
            poster_path = f"posters/{new_id}_{poster.filename}"
            with open(poster_path,"wb") as f: f.write(poster_bytes)
            poster_url = f"/{poster_path}"
        films.append({"id":new_id,"title":title,"desc":desc,"category":category,"is_premium":is_premium=="true","poster":poster_url,"file":f"{new_id}_{video.filename}","is_cloudinary":False})
    
    save_json("films.json", films)
    return {"success": True, "msg": "Film uploaded to Cloudinary! 🎉" if USE_CLOUDINARY else "Film uploaded locally!"}

@app.delete("/api/films/{film_id}")
def delete_film(film_id: str):
    films = load_json("films.json")
    films = [f for f in films if f["id"]!=film_id]
    save_json("films.json", films)
    return {"success": True}

@app.get("/api/download/{film_id}")
def download_film(film_id: str):
    films = load_json("films.json")
    film = next((x for x in films if x["id"]==film_id), None)
    if not film: return {"error": "Not found"}
    # If Cloudinary, redirect to Cloudinary URL
    if film.get("is_cloudinary"):
        from fastapi.responses import RedirectResponse
        return RedirectResponse(url=film["file"])
    return FileResponse(f"videos/{film['file']}", filename=film['file'])

# ================= PAYSTACK =================
@app.post("/api/pay/init")
def pay_init(email: str = Form(...), plan: str = Form(...)):
    prices = {"monthly": 2500*100, "yearly": 20000*100}
    amount = prices.get(plan, 2500*100)
    headers = {"Authorization": f"Bearer {PAYSTACK_SECRET}"}
    data = {"email": email, "amount": amount, "callback_url": "/flix?pay=success"}
    r = requests.post("https://api.paystack.co/transaction/initialize", json=data, headers=headers)
    res = r.json()
    return {"success": True, "url": res["data"]["authorization_url"], "reference": res["data"]["reference"]}

@app.get("/api/pay/verify/{reference}")
def pay_verify(reference: str, email: str):
    headers = {"Authorization": f"Bearer {PAYSTACK_SECRET}"}
    r = requests.get(f"https://api.paystack.co/transaction/verify/{reference}", headers=headers)
    res = r.json()
    if res["data"]["status"] == "success":
        users = load_json("users.json")
        for u in users:
            if u["email"] == email:
                u["premium_until"] = int(time.time()) + (30*24*60*60)
        save_json("users.json", users)
        return {"success": True, "msg": "Payment successful!"}
    return {"success": False, "msg": "Payment failed"}

@app.get("/api/check-premium/{email}")
def check_premium(email: str):
    if email=="admin@fortune.com": return {"premium": True}
    users = load_json("users.json")
    for u in users:
        if u["email"]==email and u.get("premium_until",0) > time.time():
            return {"premium": True}
    return {"premium": False}

@app.get("/api/config")
def get_config():
    return {"whatsapp": WHATSAPP_NUMBER, "paystack_public": PAYSTACK_PUBLIC, "cloudinary": USE_CLOUDINARY}

# ================= PAGE 1 - FORTUNE TECH =================
HTML_TECH = """
<!DOCTYPE html><html><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Fortune Tech - We Build Websites in 3 Days</title><meta name="theme-color" content="#00ff88">
<style>*{margin:0;padding:0;box-sizing:border-box;font-family:Arial}body{background:#0a0a0a;color:#fff;text-align:center;padding:20px}
.badge{background:#00ff88;color:#000;padding:6px 14px;border-radius:20px;font-weight:bold;font-size:13px}
h1{font-size:32px;margin:20px 0 10px}h1 span{color:#00ff88}p{color:#ccc;line-height:1.6}
.btn{display:inline-block;background:#00ff88;color:#000;padding:14px 28px;border-radius:10px;font-weight:bold;text-decoration:none;margin:15px 5px}
.btn.red{background:#e50914;color:#fff}.btn.white{background:#fff;color:#000}
.cards{display:flex;flex-wrap:wrap;gap:15px;justify-content:center;margin-top:30px}
.card{background:#1a1a1a;border:1px solid #333;padding:20px;border-radius:15px;width:280px;text-align:left}
.card h3{color:#00ff88}.price{font-size:28px;font-weight:bold;margin:10px 0}.card ul{list-style:none;margin:15px 0}.card li{margin:8px 0;color:#ddd}
.card a{display:block;text-align:center;background:#fff;color:#000;padding:12px;border-radius:8px;text-decoration:none;font-weight:bold}
.card.popular{border:2px solid #00ff88}
form{max-width:400px;margin:40px auto;background:#1a1a1a;padding:20px;border-radius:15px}
input,textarea{width:100%;padding:12px;margin:8px 0;border-radius:8px;border:none;outline:none}
button{padding:14px;background:#00ff88;border:none;border-radius:8px;font-weight:bold;cursor:pointer}
#waBtn{position:fixed;bottom:20px;left:20px;background:#25D366;color:#fff;padding:14px 18px;border-radius:50px;text-decoration:none;font-weight:bold;z-index:1000}
</style></head><body>
<span class="badge">🔥 FORTUNE TECH</span>
<h1>We Build Websites<br><span>in 3 Days</span></h1>
<p>For Shops, Churches, Schools & Businesses for Port Harcourt & Nigeria.</p>
<a class="btn" id="waOrder" href="#" target="_blank">Order on WhatsApp</a>
<a class="btn red" href="/flix">🎬 Watch FortuneFlix</a>
<br><button id="installBtn" style="display:none;background:#fff;color:#000;padding:12px 20px;border:none;border-radius:10px;font-weight:bold;margin-top:10px;cursor:pointer">📲 Install Fortune Tech App</button>
<h2 style="margin-top:40px">Our Pricing</h2>
<div class="cards">
<div class="card"><h3>STARTER</h3><div class="price">₦50,000</div><ul><li>✅ 1-Page Website</li><li>✅ WhatsApp Button</li><li>✅ Mobile Friendly</li><li>✅ Delivery in 3 Days</li></ul><a class="waLink" href="#" data-msg="I want Starter Package">Choose Starter</a></div>
<div class="card popular"><h3>BUSINESS ⭐</h3><div class="price">₦120,000</div><ul><li>✅ 5 Pages Website</li><li>✅ PWA - Install as App</li><li>✅ Contact Form + Google Map</li><li>✅ SEO Setup</li></ul><a class="waLink" href="#" data-msg="I want Business Package">Choose Business</a></div>
<div class="card"><h3>PREMIUM</h3><div class="price">₦250,000</div><ul><li>✅ Online Store</li><li>✅ Payment (Paystack)</li><li>✅ Admin Dashboard</li><li>✅ 1 Month Free Support</li></ul><a class="waLink" href="#" data-msg="I want Premium Package">Choose Premium</a></div>
</div>
<div style="margin-top:30px;background:#1a1a1a;padding:20px;border-radius:15px;max-width:600px;margin-left:auto;margin-right:auto"><h3>🎬 FortuneFlix - Our Latest Project</h3><p>Watch & Download Nollywood Films.</p><a class="btn red" href="/flix">Open FortuneFlix Now →</a></div>
<form id="contactForm"><h3>Contact Us</h3><input id="name" placeholder="Your Name"><input id="business" placeholder="Your Business Name"><textarea id="msg" placeholder="What website you want?"></textarea><button style="width:100%" type="submit">Send Message</button></form>
<p style="font-size:13px;color:#777">© 2026 Fortune Tech - Port Harcourt | <a href="/flix" style="color:#e50914">FortuneFlix</a></p>
<a id="waBtn" href="#" target="_blank">💬 WhatsApp</a>
<script>
async function loadConfig(){ const r=await fetch("/api/config"); const d=await r.json(); const wa=d.whatsapp; document.getElementById("waOrder").href=`https://wa.me/${wa}?text=Hi Fortune Tech, I want a website`; document.getElementById("waBtn").href=`https://wa.me/${wa}?text=Hi Fortune Tech`; document.querySelectorAll(".waLink").forEach(a=>{ a.href=`https://wa.me/${wa}?text=${encodeURIComponent(a.dataset.msg)}`; }); }
document.getElementById("contactForm").addEventListener("submit",function(e){ e.preventDefault(); let n=document.getElementById("name").value; if(!n){alert("Abeg put your name");return;} alert("Thank you "+n+"! We go contact you on WhatsApp."); });
const manifestData={name:"Fortune Tech",short_name:"FortuneTech",start_url:"/",display:"standalone",background_color:"#0a0a0a",theme_color:"#00ff88",description:"We Build Websites in 3 Days",icons:[{src:"https://picsum.photos/192",sizes:"192x192",type:"image/png"},{src:"https://picsum.photos/512",sizes:"512x512",type:"image/png"}]};
const mb=new Blob([JSON.stringify(manifestData)],{type:"application/json"}); const lk=document.createElement("link"); lk.rel="manifest"; lk.href=URL.createObjectURL(mb); document.head.appendChild(lk);
if("serviceWorker" in navigator){ const sw=`const C="fortune-tech-v1"; self.addEventListener("install",e=>{e.waitUntil(caches.open(C).then(c=>c.add("/")))}); self.addEventListener("fetch",e=>{e.respondWith(caches.match(e.request).then(r=>r||fetch(e.request)))});`; navigator.serviceWorker.register(URL.createObjectURL(new Blob([sw],{type:"text/javascript"}))); }
let dp; const ib=document.getElementById("installBtn"); window.addEventListener("beforeinstallprompt",e=>{e.preventDefault(); dp=e; ib.style.display="inline-block";}); ib.addEventListener("click",()=>{ if(dp) dp.prompt(); });
loadConfig();
</script></body></html>
"""

# ================= PAGE 2 - FORTUNEFLIX =================
HTML_FLIX = """
<!DOCTYPE html><html><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>FortuneFlix - Watch & Download Films</title><meta name="theme-color" content="#e50914">
<style>body{background:#000;color:#fff;font-family:Arial;margin:0}header{display:flex;justify-content:space-between;align-items:center;padding:15px 20px;background:#111;flex-wrap:wrap}header h1 span{color:#e50914}
input,select{padding:10px;border-radius:5px;border:none;margin:5px;color:#000}button{background:#e50914;color:#fff;border:none;padding:10px 15px;border-radius:5px;cursor:pointer;margin:5px}
button.white{background:#fff;color:#000}button.green{background:#00ff88;color:#000}
#filmGrid{display:flex;flex-wrap:wrap;gap:15px;padding:20px}.card{width:200px;background:#181818;padding:10px;border-radius:10px}.card img{width:100%;height:280px;object-fit:cover;border-radius:8px}
#player{position:fixed;top:0;left:0;width:100%;height:100%;background:rgba(0,0,0,0.97);text-align:center;padding:20px;z-index:99}video{width:90%;max-width:800px;margin-top:20px}
.modal{background:#1a1a1a;padding:20px;border-radius:10px;max-width:450px;margin:20px auto}#adminPanel{display:none;background:#111;padding:20px;margin:20px;border-radius:10px}
.badge{background:#e50914;padding:3px 8px;border-radius:5px;font-size:12px}
#waBtn{position:fixed;bottom:20px;left:20px;background:#25D366;color:#fff;padding:14px 18px;border-radius:50px;text-decoration:none;font-weight:bold;z-index:1000}
#cloudStatus{padding:10px;text-align:center;font-size:13px}
</style></head><body>
<header><h1>FORTUNE<span>FLIX</span></h1><div><a href="/" style="color:#fff">← Back to Fortune Tech</a> <input id="search" placeholder="Search films..."><select id="categoryFilter"><option>All</option></select><span id="userInfo"></span> <span id="premiumBadge"></span><button onclick="showAuth()">Login / Signup</button><button class="green" onclick="showPlans()">💎 Go Premium ₦2,500</button><button class="white" onclick="logout()">Logout</button></div></header>
<div id="cloudStatus"></div>
<div id="authBox" class="modal" style="display:none"><h3>Login / Signup</h3><input id="email" placeholder="Email - admin@fortune.com"><br><input id="password" type="password" placeholder="Password - admin123"><br><button onclick="doLogin()">Login</button><button class="white" onclick="doSignup()">Signup</button><p id="authMsg"></p><p style="font-size:12px;color:#aaa">Admin: admin@fortune.com / admin123</p></div>
<div id="plansBox" class="modal" style="display:none"><h2>💎 FortuneFlix Premium</h2><p>Watch ALL Premium films, Download unlimited</p><div style="display:flex;gap:10px;justify-content:center;flex-wrap:wrap"><div style="background:#222;padding:15px;border-radius:10px"><h3>Monthly</h3><h2>₦2,500</h2><button onclick="payNow('monthly')">Pay Monthly</button></div><div style="background:#222;padding:15px;border-radius:10px;border:2px solid #00ff88"><h3>Yearly</h3><h2>₦20,000</h2><button onclick="payNow('yearly')">Pay Yearly</button></div></div><p style="font-size:12px">Card, Transfer, Opay, USSD via Paystack</p></div>
<div id="adminPanel"><h2>🎬 Admin - Upload New Film (Cloudinary)</h2><p id="adminCloudInfo" style="color:#00ff88"></p><input id="fTitle" placeholder="Film Title"><br><input id="fDesc" placeholder="Description"><br><select id="fCat"><option>Nollywood</option><option>Comedy</option><option>Action</option><option>Drama</option><option>Horror</option></select><br><label><input type="checkbox" id="fPremium"> This film na Premium (Pay to watch)</label><br><label>Video (mp4):</label> <input type="file" id="fVideo" accept="video/*"><br><label>Poster:</label> <input type="file" id="fPoster" accept="image/*"><br><button onclick="uploadFilm()">Upload Film to Cloud</button><p id="uploadMsg"></p><progress id="uploadProgress" value="0" max="100" style="width:100%;display:none"></progress></div>
<div style="padding:0 20px"><h2>Trending Now 🔥</h2><p id="catInfo"></p></div><div id="filmGrid"></div>
<div id="player" style="display:none"><h2 id="playingTitle"></h2><video id="videoPlayer" controls></video><br><a id="downloadBtn" href="#" download><button>⬇ Download Film</button></a><button class="white" onclick="closePlayer()">Close</button></div>
<a id="waBtn" href="#" target="_blank">💬 WhatsApp</a>
<footer style="text-align:center;padding:30px;color:#888;font-size:13px">© 2026 FortuneFlix by Fortune Tech - Port Harcourt | <a href="/" style="color:#00ff88">Get Your Own Website</a></footer>
<script>
const API=""; let allFilms=[]; let WHATSAPP="2348000000000";
async function loadConfig(){ const r=await fetch(`${API}/api/config`); const d=await r.json(); WHATSAPP=d.whatsapp; document.getElementById("waBtn").href=`https://wa.me/${WHATSAPP}?text=Hi FortuneFlix`; document.getElementById("cloudStatus").innerHTML=d.cloudinary?"☁️ Cloudinary Connected - Films saved forever":"⚠️ Local Mode - Add Cloudinary keys to save forever"; document.getElementById("adminCloudInfo").innerText=d.cloudinary?"☁️ Uploading to Cloudinary - No go lost":"Local Mode"; }
function showAuth(){ document.getElementById("authBox").style.display="block"; }
function showPlans(){ const u=localStorage.getItem("user"); if(!u){ alert("Abeg login first"); showAuth(); return; } document.getElementById("plansBox").style.display="block"; }
async function doSignup(){ const fd=new FormData(); fd.append("email",document.getElementById("email").value); fd.append("password",document.getElementById("password").value); const r=await fetch(`${API}/api/signup`,{method:"POST",body:fd}); const d=await r.json(); document.getElementById("authMsg").innerText=d.msg; }
async function doLogin(){ const fd=new FormData(); fd.append("email",document.getElementById("email").value); fd.append("password",document.getElementById("password").value); const r=await fetch(`${API}/api/login`,{method:"POST",body:fd}); const d=await r.json(); if(d.success){ localStorage.setItem("user",d.email); localStorage.setItem("role",d.role); checkUser(); document.getElementById("authBox").style.display="none"; alert("Welcome "+d.email); checkPremium(); } else { document.getElementById("authMsg").innerText=d.msg; } }
function logout(){ localStorage.clear(); checkUser(); location.reload(); }
function checkUser(){ const user=localStorage.getItem("user"); const role=localStorage.getItem("role"); document.getElementById("userInfo").innerText=user?"Hi, "+user:""; document.getElementById("adminPanel").style.display=role==="admin"?"block":"none"; }
async function loadCategories(){ const r=await fetch(`${API}/api/categories`); const cats=await r.json(); document.getElementById("categoryFilter").innerHTML=cats.map(c=>`<option>${c}</option>`).join(""); }
async function loadFilms(){ const cat=document.getElementById("categoryFilter").value||"All"; const search=document.getElementById("search").value.toLowerCase(); const r=await fetch(`${API}/api/films?category=${cat}`); let films=await r.json(); if(search) films=films.filter(f=>f.title.toLowerCase().includes(search)); allFilms=films; document.getElementById("catInfo").innerText=`Showing ${films.length} films in ${cat}`; document.getElementById("filmGrid").innerHTML=films.map(f=>`<div class="card"><img src="${f.poster}"><h3>${f.title} ${f.is_premium?'🔒':''}</h3><small>${f.category} ${f.is_premium?'<span class="badge">PREMIUM</span>':''}</small><p>${f.desc}</p><button onclick="playFilm('${f.id}')">▶ Watch</button><button onclick="shareFilm('${f.id}')">📤 Share</button>${localStorage.getItem("role")==="admin"?`<button onclick="deleteFilm('${f.id}')">🗑 Delete</button>`:""}</div>`).join("")||"<p>No film yet. Admin go upload.</p>"; }
function shareFilm(id){ const f=allFilms.find(x=>x.id==id); window.open(`https://wa.me/${WHATSAPP}?text=Watch ${encodeURIComponent(f.title)} on FortuneFlix!`,"_blank"); }
async function deleteFilm(id){ if(!confirm("Delete?")) return; await fetch(`${API}/api/films/${id}`,{method:"DELETE"}); loadFilms(); loadCategories(); }
function playFilm(id){ const f=allFilms.find(x=>x.id==id); if(!f) return; const isPremiumUser=document.getElementById("premiumBadge").innerText.includes("PREMIUM"); if(f.is_premium && !isPremiumUser && localStorage.getItem("role")!=="admin"){ alert("This film na Premium! Subscribe ₦2,500"); showPlans(); return; } const player=document.getElementById("player"); const video=document.getElementById("videoPlayer"); document.getElementById("playingTitle").innerText=f.title; video.src=f.is_cloudinary?f.file:`${API}/videos/${f.file}`; document.getElementById("downloadBtn").href=`${API}/api/download/${id}`; player.style.display="block"; video.play(); }
function closePlayer(){ const v=document.getElementById("videoPlayer"); v.pause(); document.getElementById("player").style.display="none"; }
async function uploadFilm(){ const fd=new FormData(); fd.append("title",document.getElementById("fTitle").value); fd.append("desc",document.getElementById("fDesc").value); fd.append("category",document.getElementById("fCat").value); fd.append("is_premium",document.getElementById("fPremium").checked?"true":"false"); fd.append("video",document.getElementById("fVideo").files[0]); const p=document.getElementById("fPoster").files[0]; if(p) fd.append("poster",p); document.getElementById("uploadMsg").innerText="Uploading to Cloudinary... No close page, e fit take 1-2 mins for big film"; document.getElementById("uploadProgress").style.display="block"; const r=await fetch(`${API}/api/upload`,{method:"POST",body:fd}); const d=await r.json(); document.getElementById("uploadMsg").innerText=d.msg; document.getElementById("uploadProgress").style.display="none"; loadFilms(); loadCategories(); }
async function payNow(plan){ const email=localStorage.getItem("user"); const fd=new FormData(); fd.append("email",email); fd.append("plan",plan); const r=await fetch(`${API}/api/pay/init`,{method:"POST",body:fd}); const d=await r.json(); localStorage.setItem("pay_ref",d.reference); window.location.href=d.url; }
async function checkPaymentReturn(){ const params=new URLSearchParams(window.location.search); const ref=params.get("reference")||localStorage.getItem("pay_ref"); const email=localStorage.getItem("user"); if(ref && email && params.get("pay")==="success"){ const r=await fetch(`${API}/api/pay/verify/${ref}?email=${email}`); const d=await r.json(); if(d.success){ alert("Premium Activated! 🎉"); localStorage.removeItem("pay_ref"); checkPremium(); } } }
async function checkPremium(){ const email=localStorage.getItem("user"); if(!email) return; const r=await fetch(`${API}/api/check-premium/${email}`); const d=await r.json(); if(d.premium) document.getElementById("premiumBadge").innerHTML="💎 PREMIUM ACTIVE"; }
const manifestData={name:"FortuneFlix",short_name:"FortuneFlix",start_url:"/flix",display:"standalone",background_color:"#000000",theme_color:"#e50914",description:"Watch & Download Films",icons:[{src:"https://picsum.photos/192",sizes:"192x192",type:"image/png"},{src:"https://picsum.photos/512",sizes:"512x512",type:"image/png"}]};
const mb=new Blob([JSON.stringify(manifestData)],{type:"application/json"}); const lk=document.createElement("link"); lk.rel="manifest"; lk.href=URL.createObjectURL(mb); document.head.appendChild(lk);
if("serviceWorker" in navigator){ const sw=`const C="fortuneflix-v2"; self.addEventListener("install",e=>{e.waitUntil(caches.open(C).then(c=>c.add("/flix")))}); self.addEventListener("fetch",e=>{e.respondWith(caches.match(e.request).then(r=>r||fetch(e.request)))});`; navigator.serviceWorker.register(URL.createObjectURL(new Blob([sw],{type:"text/javascript"}))); }
let dp; window.addEventListener("beforeinstallprompt",e=>{e.preventDefault(); dp=e; const b=document.createElement("button"); b.innerText="📲 Install FortuneFlix App"; b.style.cssText="position:fixed;bottom:20px;right:20px;background:#e50914;color:#fff;padding:12px 20px;border:none;border-radius:20px;z-index:999"; b.onclick=()=>dp.prompt(); document.body.appendChild(b); });
document.getElementById("search")?.addEventListener("input",loadFilms);
document.getElementById("categoryFilter")?.addEventListener("change",loadFilms);
loadConfig(); checkUser(); loadCategories(); loadFilms(); checkPaymentReturn(); checkPremium();
</script></body></html>
"""

@app.get("/", response_class=HTMLResponse)
def home():
    return HTML_TECH

@app.get("/flix", response_class=HTMLResponse)
def flix():
    return HTML_FLIX

if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=10000)
