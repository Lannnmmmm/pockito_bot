(() => {
  const $ = (s, root=document) => root.querySelector(s);
  const $$ = (s, root=document) => [...root.querySelectorAll(s)];
  const cfg = window.POCKITO_CONFIG || {};
  let supabase = null, session = null, user = null, workspaces = [], activeWorkspace = null, role = "viewer";
  let wallets = [], categories = [], transactions = [], goals = [], goalAllocations = [], page = "overview", txKind = "expense", authMode = "login";
  const pageNames = {overview:["OVERVIEW","Ringkasan keuangan"],transactions:["CATATAN","Transaksi"],wallets:["AKUN","Dompet"],categories:["PENGATURAN","Kategori"],budgets:["PERENCANAAN","Anggaran"],goals:["PERENCANAAN","Target dana"],installments:["KOMITMEN","Cicilan & kartu"],debts:["KOMITMEN","Utang & piutang"],investments:["ASET","Investasi"],recurring:["OTOMASI","Transaksi rutin"]};
  const money = n => new Intl.NumberFormat("id-ID",{style:"currency",currency:"IDR",maximumFractionDigits:0}).format(Number(n||0));
  const dateFmt = v => new Intl.DateTimeFormat("id-ID",{day:"2-digit",month:"short",year:"numeric"}).format(new Date(v));
  const escapeHtml = s => String(s ?? "").replace(/[&<>"']/g,c=>({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;","'":"&#39;"}[c]));
  const toast = (message,error=false) => { const el=$("#toast"); el.textContent=message; el.className="toast show"+(error?" error":""); clearTimeout(toast.timer); toast.timer=setTimeout(()=>el.className="toast",3400); };
  const fail = e => { console.error(e); toast(e?.message || "Terjadi kesalahan. Coba lagi.",true); };
  const canEdit = () => ["owner","admin","editor"].includes(role);
  const key = () => (crypto.randomUUID ? crypto.randomUUID() : "pockito-"+Date.now()+"-"+Math.random().toString(36).slice(2));
  const showAuth = () => { $("#auth-screen").classList.remove("hidden"); $("#app-shell").classList.add("hidden"); };
  const showApp = () => { $("#auth-screen").classList.add("hidden"); $("#app-shell").classList.remove("hidden"); };
  const call = async (query) => { const {data,error}=await query; if(error) throw error; return data; };

  function setAuthMode(mode){
    authMode=mode;
    $$(".tab").forEach(b=>b.classList.toggle("active",b.dataset.authMode===mode));
    $("#name-wrap").classList.toggle("hidden",mode!=="signup");
    $("#auth-submit").innerHTML=mode==="signup"?"Buat akun <span>→</span>":"Masuk ke Pockito <span>→</span>";
    $("#auth-hint").textContent=mode==="signup"?"Pendaftaran akan membuat Personal Workspace secara otomatis.":"Gunakan akun Pockito Workspace kamu.";
  }
  async function submitAuth(e){
    e.preventDefault();
    const email=$("#auth-email").value.trim(), password=$("#auth-password").value;
    $("#auth-submit").disabled=true;
    try{
      if(authMode==="signup"){
        const display_name=$("#auth-name").value.trim();
        const {data,error}=await supabase.auth.signUp({email,password,options:{data:{display_name}}});
        if(error) throw error;
        if(!data.session) toast("Akun dibuat. Cek email untuk verifikasi, lalu masuk.");
        else toast("Akun berhasil dibuat.");
      }else{
        const {error}=await supabase.auth.signInWithPassword({email,password}); if(error) throw error;
      }
    }catch(e){fail(e)}finally{$("#auth-submit").disabled=false}
  }

  async function loadWorkspaceContext(){
    workspaces=await call(supabase.from("workspaces").select("id,name,kind").order("created_at"));
    if(!workspaces.length) throw new Error("Workspace belum tersedia. Coba keluar lalu masuk kembali; pastikan migration 0002 berhasil.");
    const preferred=localStorage.getItem("pockito_workspace_id");
    activeWorkspace=workspaces.find(w=>w.id===preferred)||workspaces.find(w=>w.kind==="personal")||workspaces[0];
    $("#workspace-select").innerHTML=workspaces.map(w=>'<option value="'+w.id+'">'+escapeHtml(w.name)+(w.kind==="personal"?" · Pribadi":" · Bersama")+"</option>").join("");
    $("#workspace-select").value=activeWorkspace.id;
    await loadWorkspace();
  }
  async function loadWorkspace(){
    activeWorkspace=workspaces.find(w=>w.id===$("#workspace-select").value)||activeWorkspace;
    if(!activeWorkspace)return;
    localStorage.setItem("pockito_workspace_id",activeWorkspace.id);
    const member=await call(supabase.from("workspace_members").select("role").eq("workspace_id",activeWorkspace.id).eq("user_id",user.id).is("removed_at",null).single());
    role=member?.role||"viewer"; $("#role-label").textContent="Peran: "+role;
    await Promise.all([loadWallets(),loadCategories(),loadTransactions(),loadGoals()]);
    renderPage();
  }
  async function loadWallets(){
    const rows=await call(supabase.from("wallets").select("id,name,wallet_type,account_label,opening_balance,is_active").eq("workspace_id",activeWorkspace.id).eq("is_active",true).order("created_at"));
    const ledgers=await call(supabase.from("ledger_entries").select("wallet_id,signed_amount").eq("workspace_id",activeWorkspace.id));
    wallets=rows.map(w=>({...w,balance:Number(w.opening_balance||0)+ledgers.filter(x=>x.wallet_id===w.id).reduce((s,x)=>s+Number(x.signed_amount),0)}));
  }
  async function loadCategories(){
    categories=await call(supabase.from("categories").select("id,name,category_type,is_system").eq("workspace_id",activeWorkspace.id).order("name"));
  }
  async function loadTransactions(){
    transactions=await call(supabase.from("transactions").select("id,wallet_id,category_id,kind,amount,occurred_at,title,notes,source,reversed_at,reverses_transaction_id").eq("workspace_id",activeWorkspace.id).order("occurred_at",{ascending:false}).limit(100));
  }
  async function loadGoals(){
    const [goalRows,allocationRows]=await Promise.all([
      call(supabase.from("goals").select("id,name,target_amount,deadline,notes,status,created_at,updated_at").eq("workspace_id",activeWorkspace.id).order("created_at",{ascending:false})),
      call(supabase.from("goal_allocations").select("id,goal_id,wallet_id,transaction_id,kind,amount,occurred_at,notes").eq("workspace_id",activeWorkspace.id).order("occurred_at",{ascending:false}).limit(500))
    ]);
    goals=goalRows||[];goalAllocations=allocationRows||[];
  }
  function updateHeader(){
    const [ey,title]=pageNames[page]||pageNames.overview; $("#page-eyebrow").textContent=ey; $("#page-title").textContent=title;
    $$(".nav-item").forEach(b=>b.classList.toggle("active",b.dataset.page===page));
  }
  function txRows(items){
    if(!items.length)return '<div class="empty"><div class="empty-icon">◌</div>Belum ada transaksi. Catat transaksi pertamamu.</div>';
    return '<div class="tx-list">'+items.map(t=>{
      const transfer=t.kind==="transfer_in"||t.kind==="transfer_out";
      const inc=t.kind==="income"||t.kind==="asset_in"||t.kind==="transfer_in";
      const wallet=wallets.find(w=>w.id===t.wallet_id); const cat=categories.find(c=>c.id===t.category_id);
      const amountClass=transfer?"transfer-text":inc?"positive":"negative";
      const iconClass=transfer?"transfer":inc?"income":"expense";
      return '<div class="tx-row"><div class="tx-icon '+iconClass+'">'+(transfer?"⇄":inc?"↙":"↗")+'</div><div class="tx-main"><strong>'+escapeHtml(t.title)+'</strong><small>'+escapeHtml(cat?.name||t.source||"Transaksi")+' · '+escapeHtml(wallet?.name||"Dompet")+' · '+dateFmt(t.occurred_at)+(t.reversed_at?" · Dibatalkan":"")+'</small></div><div class="tx-amount '+amountClass+'">'+(t.kind==="transfer_out"?"−":inc?"+":"−")+money(t.amount)+'</div></div>';
    }).join("")+'</div>';
  }
  function renderOverview(){
    const balance=wallets.reduce((s,w)=>s+w.balance,0);
    const month=new Date(); const monthTx=transactions.filter(t=>{const d=new Date(t.occurred_at);return d.getMonth()===month.getMonth()&&d.getFullYear()===month.getFullYear()&&!t.reversed_at&&!t.reverses_transaction_id;});
    const income=monthTx.filter(t=>t.kind==="income").reduce((s,t)=>s+Number(t.amount),0);
    const expense=monthTx.filter(t=>t.kind==="expense").reduce((s,t)=>s+Number(t.amount),0);
    return '<div class="welcome-row"><div><strong>Halo, '+escapeHtml(user.user_metadata?.display_name||user.email?.split("@")[0]||"teman")+' 👋</strong><p>Ini gambaran keuangan di workspace '+escapeHtml(activeWorkspace.name)+'.</p></div><span class="role-tag">'+(activeWorkspace.kind==="personal"?"Ruang pribadi":"Ruang bersama")+'</span></div>'+
      '<div class="metric-grid"><article class="metric primary-metric"><div class="metric-label">Total saldo dompet</div><div class="metric-value">'+money(balance)+'</div><div class="metric-foot">Akumulasi saldo seluruh dompet aktif</div></article><article class="metric"><div class="metric-label">Pemasukan bulan ini</div><div class="metric-value positive">'+money(income)+'</div><div class="metric-foot">Transaksi pemasukan</div></article><article class="metric"><div class="metric-label">Pengeluaran bulan ini</div><div class="metric-value negative">'+money(expense)+'</div><div class="metric-foot">Transaksi pengeluaran</div></article><article class="metric"><div class="metric-label">Arus kas bulan ini</div><div class="metric-value">'+money(income-expense)+'</div><div class="metric-foot">'+monthTx.length+' transaksi tercatat</div></article></div>'+
      '<div class="dashboard-grid"><section class="panel"><div class="panel-title"><h3>Transaksi terbaru</h3><button class="text-btn" data-goto="transactions">Lihat semua →</button></div>'+txRows(transactions.slice(0,6))+'</section><section class="panel"><div class="panel-title"><h3>Dompet</h3><button class="text-btn" data-goto="wallets">Kelola →</button></div>'+walletList()+'</section></div>';
  }
  function walletList(){
    if(!wallets.length)return '<div class="empty">Belum ada dompet.<br>Tambahkan rekening atau uang tunai.</div>';
    return '<div class="wallet-list">'+wallets.map(w=>'<div class="wallet-row"><div class="wallet-info"><div class="wallet-icon">▣</div><div><strong>'+escapeHtml(w.name)+'</strong><small>'+escapeHtml(w.wallet_type||"Dompet")+'</small></div></div><div class="wallet-balance">'+money(w.balance)+'</div></div>').join("")+'</div>';
  }
  function renderTransactions(){
    return '<div class="page-toolbar"><input class="search-input" id="tx-search" placeholder="Cari transaksi..." /><button class="btn primary" data-open="transaction-dialog">＋ Transaksi</button></div><div class="table-wrap"><table><thead><tr><th>TANGGAL</th><th>TRANSAKSI</th><th>KATEGORI</th><th>DOMPET</th><th>JENIS</th><th>NOMINAL</th></tr></thead><tbody id="transactions-body">'+transactions.map(t=>transactionTableRow(t)).join("")+'</tbody></table></div>';
  }
  function transactionTableRow(t){
    const transfer=t.kind==="transfer_in"||t.kind==="transfer_out";const inc=t.kind==="income"||t.kind==="asset_in"||t.kind==="transfer_in";const label=transfer?"Transfer":(inc?"Pemasukan":"Pengeluaran");return '<tr><td>'+dateFmt(t.occurred_at)+'</td><td><strong>'+escapeHtml(t.title)+'</strong>'+(t.reversed_at?'<div class="tiny muted">Dibatalkan</div>':"")+'</td><td>'+escapeHtml(categories.find(c=>c.id===t.category_id)?.name||"—")+'</td><td>'+escapeHtml(wallets.find(w=>w.id===t.wallet_id)?.name||"—")+'</td><td><span class="pill '+(transfer?"transfer":inc?"income":"expense")+'">'+label+'</span></td><td class="'+(transfer?"transfer-text":inc?"positive":"negative")+'">'+(t.kind==="transfer_out"?"−":inc?"+":"−")+money(t.amount)+'</td></tr>';
  }
  function renderWallets(){
    return '<div class="page-toolbar"><div class="muted">Saldo dihitung dari saldo awal + seluruh ledger, bukan angka manual.</div><div class="toolbar-actions"><button class="btn ghost" data-action="transfer">⇄ Transfer</button><button class="btn primary" data-open="wallet-dialog">＋ Tambah dompet</button></div></div><div class="card-grid">'+(wallets.length?wallets.map(w=>'<article class="wallet-card"><div class="wallet-info"><div class="wallet-icon">▣</div><div><strong>'+escapeHtml(w.name)+'</strong><small>'+escapeHtml(w.wallet_type)+'</small></div></div><div class="wallet-balance">'+money(w.balance)+'</div><small>'+escapeHtml(w.account_label||"")+'</small></article>').join(""):'<div class="panel empty">Belum ada dompet.</div>')+'</div>';
  }
  function renderCategories(){
    return '<div class="page-toolbar"><div class="muted">Kategori membantu mengelompokkan arus kas.</div><button class="btn primary" data-open="category-dialog">＋ Tambah kategori</button></div><div class="table-wrap"><table><thead><tr><th>NAMA</th><th>JENIS</th><th>SUMBER</th></tr></thead><tbody>'+categories.map(c=>'<tr><td><strong>'+escapeHtml(c.name)+'</strong></td><td>'+escapeHtml(c.category_type)+'</td><td>'+(c.is_system?"Sistem":"Kustom")+'</td></tr>').join("")+'</tbody></table></div>';
  }
  function goalBalance(goalId,walletId=null){
    return goalAllocations.filter(a=>a.goal_id===goalId&&(!walletId||a.wallet_id===walletId)).reduce((sum,a)=>sum+(a.kind==="reserve"?Number(a.amount):-Number(a.amount)),0);
  }
  function renderGoals(){
    const active=goals.filter(g=>g.status==="active");
    const totalTarget=active.reduce((s,g)=>s+Number(g.target_amount),0);
    const totalSaved=active.reduce((s,g)=>s+Math.max(0,goalBalance(g.id)),0);
    const statusLabel={active:"Aktif",completed:"Tercapai",paused:"Ditunda",cancelled:"Dibatalkan"};
    const cards=goals.map(g=>{
      const saved=goalBalance(g.id),target=Number(g.target_amount),pct=Math.max(0,Math.round(saved/target*100));
      const editable=canEdit();
      return '<article class="goal-card"><div class="goal-card-head"><div><span class="goal-status '+escapeHtml(g.status)+'">'+(statusLabel[g.status]||g.status)+'</span><h3>'+escapeHtml(g.name)+'</h3></div><button class="icon-btn goal-edit" data-goal-action="edit" data-goal-id="'+g.id+'" aria-label="Edit target">···</button></div><div class="goal-amounts"><strong>'+money(saved)+'</strong><span>dari '+money(target)+'</span></div><div class="goal-progress"><span style="width:'+Math.min(pct,100)+'%"></span></div><div class="goal-meta"><span>'+pct+'% terkumpul</span><span>'+(g.deadline?"Target "+dateFmt(g.deadline):"Tanpa tenggat")+'</span></div>'+(editable&&g.status==="active"?'<div class="goal-actions"><button class="btn ghost" data-goal-action="reserve" data-goal-id="'+g.id+'">＋ Sisihkan</button><button class="btn ghost" data-goal-action="release" data-goal-id="'+g.id+'">Ambil kembali</button><button class="btn primary" data-goal-action="spend" data-goal-id="'+g.id+'">Gunakan dana</button></div>':"")+'</article>';
    }).join("");
    const activity=goalAllocations.slice(0,30).map(a=>{
      const g=goals.find(x=>x.id===a.goal_id),w=wallets.find(x=>x.id===a.wallet_id);
      const label=a.kind==="reserve"?"Dana disisihkan":a.kind==="release"?"Dana diambil kembali":"Pengeluaran target";
      const sign=a.kind==="reserve"?"+":"−";
      return '<tr><td>'+dateFmt(a.occurred_at)+'</td><td><strong>'+escapeHtml(g?.name||"Target dihapus")+'</strong><div class="tiny muted">'+label+'</div></td><td>'+escapeHtml(w?.name||"—")+'</td><td class="'+(a.kind==="reserve"?"positive":"negative")+'">'+sign+money(a.amount)+'</td></tr>';
    }).join("");
    return '<div class="goal-summary"><div><span class="metric-label">Target aktif</span><strong>'+active.length+'</strong></div><div><span class="metric-label">Total sasaran</span><strong>'+money(totalTarget)+'</strong></div><div><span class="metric-label">Dana terkumpul</span><strong>'+money(totalSaved)+'</strong></div></div><div class="page-toolbar"><div class="muted">Alokasi bukan pengeluaran. Saldo dompet baru berkurang saat dana benar-benar digunakan.</div>'+(canEdit()?'<button class="btn primary" data-goal-action="new">＋ Buat target</button>':"")+'</div>'+(goals.length?'<div class="goal-grid">'+cards+'</div>':'<div class="panel empty">Belum ada target dana. Buat target pertama untuk mulai menyisihkan uang.</div>')+'<section class="panel goal-history"><div class="panel-title"><h3>Riwayat alokasi</h3><span class="tiny muted">30 aktivitas terbaru</span></div>'+(activity?'<div class="table-wrap"><table><thead><tr><th>TANGGAL</th><th>AKTIVITAS</th><th>DOMPET</th><th>NOMINAL</th></tr></thead><tbody>'+activity+'</tbody></table></div>':'<div class="empty">Belum ada aktivitas alokasi dana.</div>')+'</section>';
  }
  const moduleDescriptions={
    budgets:["Anggaran bulanan","Tetapkan batas pengeluaran per kategori dan pantau realisasi berdasarkan transaksi.","Anggaran dan kategori anggaran sudah tersedia di database. UI pengaturan dan kalkulasi akan diselesaikan pada tahap modul ini."],
    goals:["Target dana","Pisahkan dana untuk tujuan tertentu tanpa menganggap alokasi sebagai pengeluaran.","Pencatatan reserve, release, dan spend tersedia melalui RPC. UI pengelolaan target dan riwayat alokasi menyusul."],
    installments:["Cicilan & kartu","Kelola kartu kredit, jadwal cicilan, pembayaran sebagian, dan riwayat pelunasan.","Struktur kartu, cicilan, serta RPC pembayaran dan pembatalan sudah disiapkan. UI operasional modul ini belum aktif."],
    debts:["Utang & piutang","Pantau kewajiban dan tagihan, termasuk pembayaran bertahap.","Database dan RPC pembayaran utang/piutang tersedia. UI pengelolaan dan riwayat pembayaran belum aktif."],
    investments:["Investasi","Catat modal, pencairan, dan perubahan nilai aset tanpa mencampur valuasi dengan arus kas.","RPC kontribusi, pencairan, valuasi, dan penutupan investasi tersedia. UI investasi belum aktif."],
    recurring:["Transaksi rutin","Jadwalkan pemasukan dan pengeluaran bulanan agar tidak terlewat.","RPC simpan, jeda, dan eksekusi tersedia. Catatan: eksekusi belum berjalan otomatis; perlu pemanggilan terjadwal."]
  };
  function renderModule(){
    const [name,desc,note]=moduleDescriptions[page];
    return '<div class="module-intro"><span class="module-state">UI DALAM PENGEMBANGAN</span><h3>'+name+'</h3><p>'+desc+'</p><p><strong>Status teknis:</strong> '+note+'</p><p class="tiny">Modul ini sengaja belum menampilkan tombol simulasi yang belum terhubung ke operasi database. Kami aktifkan setelah seluruh alur dan validasi siap.</p></div>';
  }
  function renderPage(){
    updateHeader(); const el=$("#page-content");
    el.innerHTML=page==="overview"?renderOverview():page==="transactions"?renderTransactions():page==="wallets"?renderWallets():page==="categories"?renderCategories():page==="goals"?renderGoals():renderModule();
    if(page==="transactions")$("#tx-search").addEventListener("input",e=>{const q=e.target.value.toLowerCase();$("#transactions-body").innerHTML=transactions.filter(t=>(t.title||"").toLowerCase().includes(q)).map(transactionTableRow).join("");});
  }
  function openGoalForm(goalId=null){
    if(!canEdit())return toast("Akses workspace kamu hanya bisa melihat data.",true);
    const form=$("#goal-form");form.reset();
    const goal=goalId?goals.find(g=>g.id===goalId):null;
    $("#goal-id").value=goal?.id||"";
    $("#goal-dialog-title").textContent=goal?"Ubah target dana":"Buat target dana";
    $("#goal-name").value=goal?.name||"";
    $("#goal-target").value=goal?.target_amount||"";
    $("#goal-deadline").value=goal?.deadline||"";
    $("#goal-notes").value=goal?.notes||"";
    $("#goal-status").value=goal?.status||"active";
    $("#goal-dialog").showModal();
  }
  function openGoalAction(kind,goalId){
    if(!canEdit())return toast("Akses workspace kamu hanya bisa melihat data.",true);
    const goal=goals.find(g=>g.id===goalId);if(!goal)return;
    const walletOptions=wallets.map(w=>'<option value="'+w.id+'">'+escapeHtml(w.name)+' · '+money(w.balance)+'</option>').join("");
    $("#goal-action-wallet").innerHTML=walletOptions;
    $("#goal-action-kind").value=kind;
    $("#goal-action-id").value=goal.id;
    $("#goal-action-title").textContent=kind==="reserve"?"Sisihkan dana":kind==="release"?"Ambil kembali dana":"Gunakan dana";
    $("#goal-action-description").textContent=kind==="reserve"?"Dana ditandai untuk target ini, saldo dompet tidak berubah.":kind==="release"?"Dana dilepas dari target dan kembali menjadi dana bebas.":"Pengeluaran nyata akan dicatat dan saldo dompet berkurang.";
    $("#goal-action-name").value=kind==="spend"?"Pengeluaran: "+goal.name:"";
    $("#goal-action-amount").value="";
    $("#goal-action-notes").value="";
    $("#goal-action-date").value=new Date(Date.now()-new Date().getTimezoneOffset()*60000).toISOString().slice(0,16);
    const expenseCategories=categories.filter(c=>c.category_type==="both"||c.category_type==="expense");
    $("#goal-action-category").innerHTML='<option value="">Tanpa kategori</option>'+expenseCategories.map(c=>'<option value="'+c.id+'">'+escapeHtml(c.name)+'</option>').join("");
    $("#goal-spend-fields").classList.toggle("hidden",kind!=="spend");
    $("#goal-action-submit").textContent=kind==="reserve"?"Sisihkan dana":kind==="release"?"Ambil kembali":"Catat pengeluaran";
    $("#goal-action-dialog").showModal();
  }
  async function saveGoal(e){
    e.preventDefault();if(!canEdit())return;
    const id=$("#goal-id").value;
    const amount=Number($("#goal-target").value);
    if(!Number.isSafeInteger(amount)||amount<=0)return toast("Target harus berupa Rupiah bulat lebih dari nol.",true);
    const args={p_workspace_id:activeWorkspace.id,p_name:$("#goal-name").value.trim(),p_target_amount:amount,p_deadline:$("#goal-deadline").value||null,p_notes:$("#goal-notes").value.trim()||null};
    const btn=$("#goal-submit");btn.disabled=true;
    try{
      if(id)await call(supabase.rpc("update_goal",{...args,p_goal_id:id,p_status:$("#goal-status").value}));
      else await call(supabase.rpc("create_goal",args));
      $("#goal-dialog").close();await refreshData();toast(id?"Target berhasil diperbarui.":"Target berhasil dibuat.");
    }catch(e){fail(e)}finally{btn.disabled=false}
  }
  async function saveGoalAction(e){
    e.preventDefault();if(!canEdit())return;
    const kind=$("#goal-action-kind").value,goalId=$("#goal-action-id").value,walletId=$("#goal-action-wallet").value;
    const amount=Number($("#goal-action-amount").value);
    if(!walletId)return toast("Pilih dompet terlebih dahulu.",true);
    if(!Number.isSafeInteger(amount)||amount<=0)return toast("Nominal harus berupa Rupiah bulat lebih dari nol.",true);
    const common={p_workspace_id:activeWorkspace.id,p_goal_id:goalId,p_wallet_id:walletId,p_amount:amount,p_occurred_at:new Date($("#goal-action-date").value).toISOString(),p_notes:$("#goal-action-notes").value.trim()||null,p_idempotency_key:key()};
    const btn=$("#goal-action-submit");btn.disabled=true;
    try{
      if(kind==="spend")await call(supabase.rpc("spend_goal_funds",{...common,p_title:$("#goal-action-name").value.trim()||null,p_category_id:$("#goal-action-category").value||null}));
      else await call(supabase.rpc("allocate_goal_funds",{...common,p_kind:kind}));
      $("#goal-action-dialog").close();$("#goal-action-form").reset();await refreshData();
      toast(kind==="reserve"?"Dana berhasil disisihkan.":kind==="release"?"Dana berhasil diambil kembali.":"Pengeluaran target berhasil dicatat.");
    }catch(e){fail(e)}finally{btn.disabled=false}
  }
  async function openTransaction(){
    if(!canEdit())return toast("Akses workspace kamu hanya bisa melihat data.",true);
    $("#tx-wallet").innerHTML=wallets.map(w=>'<option value="'+w.id+'">'+escapeHtml(w.name)+'</option>').join("");
    fillCategories();$("#tx-date").value=new Date(Date.now()-new Date().getTimezoneOffset()*60000).toISOString().slice(0,16);
    $("#transaction-dialog").showModal();
  }
  function fillCategories(){
    const filtered=categories.filter(c=>c.category_type==="both"||c.category_type===txKind);
    $("#tx-category").innerHTML='<option value="">Tanpa kategori</option>'+filtered.map(c=>'<option value="'+c.id+'">'+escapeHtml(c.name)+'</option>').join("");
  }
  async function saveTransaction(e){
    e.preventDefault();if(!canEdit())return;
    const amount=Number($("#tx-amount").value);
    if(!Number.isSafeInteger(amount)||amount<=0)return toast("Nominal harus berupa Rupiah bulat lebih dari nol.",true);
    const args={p_workspace_id:activeWorkspace.id,p_wallet_id:$("#tx-wallet").value,p_kind:txKind,p_amount:amount,p_occurred_at:new Date($("#tx-date").value).toISOString(),p_title:$("#tx-title").value.trim(),p_category_id:$("#tx-category").value||null,p_notes:$("#tx-notes").value.trim()||null,p_source:"manual",p_idempotency_key:key()};
    const btn=$("#tx-submit");btn.disabled=true;
    try{await call(supabase.rpc("post_financial_transaction",args));$("#transaction-dialog").close();$("#transaction-form").reset();await refreshData();toast("Transaksi berhasil disimpan.");}
    catch(e){fail(e)}finally{btn.disabled=false}
  }
  function openTransfer(){
    if(!canEdit())return toast("Akses workspace kamu hanya bisa melihat data.",true);
    if(wallets.length<2)return toast("Tambahkan minimal dua dompet untuk melakukan transfer.",true);
    const options=wallets.map(w=>'<option value="'+w.id+'">'+escapeHtml(w.name)+' · '+money(w.balance)+'</option>').join("");
    $("#transfer-source").innerHTML=options;
    $("#transfer-destination").innerHTML=options;
    if(wallets[1])$("#transfer-destination").value=wallets[1].id;
    $("#transfer-date").value=new Date(Date.now()-new Date().getTimezoneOffset()*60000).toISOString().slice(0,16);
    updateTransferHint();
    $("#transfer-dialog").showModal();
  }
  function updateTransferHint(){
    const source=wallets.find(w=>w.id===$("#transfer-source").value);
    const destination=wallets.find(w=>w.id===$("#transfer-destination").value);
    $("#transfer-balance-hint").textContent=(source?"Saldo sumber: "+money(source.balance):"Pilih dompet sumber.")+(destination?" · Saldo tujuan: "+money(destination.balance):"");
  }
  async function saveTransfer(e){
    e.preventDefault();if(!canEdit())return;
    const sourceId=$("#transfer-source").value,destinationId=$("#transfer-destination").value;
    const amount=Number($("#transfer-amount").value);
    const source=wallets.find(w=>w.id===sourceId);
    if(!sourceId||!destinationId||sourceId===destinationId)return toast("Pilih dua dompet yang berbeda.",true);
    if(!Number.isSafeInteger(amount)||amount<=0)return toast("Nominal harus berupa Rupiah bulat lebih dari nol.",true);
    if(source&&amount>source.balance)return toast("Saldo dompet sumber tidak mencukupi.",true);
    const args={p_workspace_id:activeWorkspace.id,p_source_wallet_id:sourceId,p_destination_wallet_id:destinationId,p_amount:amount,p_occurred_at:new Date($("#transfer-date").value).toISOString(),p_title:$("#transfer-title").value.trim(),p_notes:$("#transfer-notes").value.trim()||null,p_idempotency_key:key()};
    const btn=$("#transfer-submit");btn.disabled=true;
    try{await call(supabase.rpc("post_wallet_transfer",args));$("#transfer-dialog").close();$("#transfer-form").reset();await refreshData();toast("Transfer berhasil dicatat.");}
    catch(e){fail(e)}finally{btn.disabled=false}
  }
  async function saveWallet(e){
    e.preventDefault();if(!canEdit())return;
    const name=$("#wallet-name").value.trim(), opening=Number($("#wallet-opening").value||0);
    if(!Number.isSafeInteger(opening)||opening<0)return toast("Saldo awal tidak valid.",true);
    try{await call(supabase.from("wallets").insert({workspace_id:activeWorkspace.id,name,wallet_type:$("#wallet-type").value,account_label:$("#wallet-label").value.trim()||null,opening_balance:opening,created_by:user.id}));$("#wallet-dialog").close();$("#wallet-form").reset();await refreshData();toast("Dompet berhasil dibuat.");}
    catch(e){fail(e)}
  }
  async function saveCategory(e){
    e.preventDefault();if(!canEdit())return;
    try{await call(supabase.from("categories").insert({workspace_id:activeWorkspace.id,name:$("#category-name").value.trim(),category_type:$("#category-type").value}));$("#category-dialog").close();$("#category-form").reset();await loadCategories();renderPage();toast("Kategori berhasil dibuat.");}
    catch(e){fail(e)}
  }
  async function refreshData(){await Promise.all([loadWallets(),loadCategories(),loadTransactions(),loadGoals()]);renderPage();}
  async function enterApp(currentSession){
    session=currentSession;user=currentSession.user;
    $("#user-name").textContent=user.user_metadata?.display_name||user.email?.split("@")[0]||"Pengguna";
    $("#user-email").textContent=user.email||"";$("#user-avatar").textContent=($("#user-name").textContent[0]||"P").toUpperCase();
    $("#today-label").textContent=new Intl.DateTimeFormat("id-ID",{weekday:"long",day:"numeric",month:"long"}).format(new Date());
    showApp();try{await loadWorkspaceContext()}catch(e){fail(e);showAuth()}
  }
  function bind(){
    $$(".tab").forEach(b=>b.addEventListener("click",()=>setAuthMode(b.dataset.authMode)));
    $("#auth-form").addEventListener("submit",submitAuth);
    $("#main-nav").addEventListener("click",e=>{const b=e.target.closest("[data-page]");if(!b)return;page=b.dataset.page;$("#sidebar")?.classList.remove("open");$(".sidebar").classList.remove("open");renderPage();});
    $("#workspace-select").addEventListener("change",async()=>{try{await loadWorkspace()}catch(e){fail(e)}});
    $("#quick-add").addEventListener("click",openTransaction);
    $("#page-content").addEventListener("click",e=>{const goalAction=e.target.closest("[data-goal-action]");if(goalAction){const action=goalAction.dataset.goalAction;if(action==="new")openGoalForm();else if(action==="edit")openGoalForm(goalAction.dataset.goalId);else openGoalAction(action,goalAction.dataset.goalId);return;}const open=e.target.closest("[data-open]");if(open){if(open.dataset.open==="transaction-dialog")openTransaction();else if(canEdit())$("#"+open.dataset.open).showModal();else toast("Kamu memiliki akses baca saja.",true);return;}const goto=e.target.closest("[data-goto]");if(goto){page=goto.dataset.goto;renderPage();}});
    $("#transaction-form").addEventListener("submit",saveTransaction);$("#wallet-form").addEventListener("submit",saveWallet);$("#category-form").addEventListener("submit",saveCategory);$("#transfer-form").addEventListener("submit",saveTransfer);$("#goal-form").addEventListener("submit",saveGoal);$("#goal-action-form").addEventListener("submit",saveGoalAction);$("#transfer-source").addEventListener("change",updateTransferHint);$("#transfer-destination").addEventListener("change",updateTransferHint);$("#page-content").addEventListener("click",e=>{if(e.target.closest("[data-action=transfer]"))openTransfer();});
    $$(".segmented [data-kind]").forEach(b=>b.addEventListener("click",()=>{txKind=b.dataset.kind;$$(".segmented [data-kind]").forEach(x=>x.classList.toggle("active",x===b));fillCategories();}));
    $$("[data-close]").forEach(b=>b.addEventListener("click",()=>$("#"+b.dataset.close).close()));
    $("#signout-btn").addEventListener("click",()=>supabase.auth.signOut());
    $("#mobile-menu").addEventListener("click",()=>$(".sidebar").classList.toggle("open"));
  }
  async function boot(){
    if(!cfg.SUPABASE_URL||!cfg.SUPABASE_ANON_KEY){showAuth();$("#auth-hint").textContent="Konfigurasi belum diisi. Buka web/config.js lalu isi Project URL dan publishable/anon key dari Supabase Workspace.";$("#auth-submit").disabled=true;return;}
    supabase=window.supabase.createClient(cfg.SUPABASE_URL,cfg.SUPABASE_ANON_KEY);
    bind();
    const {data:{session:current}}=await supabase.auth.getSession();
    if(current)await enterApp(current);else showAuth();
    supabase.auth.onAuthStateChange((_event,newSession)=>{if(newSession){setTimeout(()=>enterApp(newSession),0)}else{session=null;user=null;showAuth();}});
  }
  document.addEventListener("DOMContentLoaded",boot);
})();