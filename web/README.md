# Pockito Web

Frontend baru untuk arsitektur Personal + Shared Workspace.

## Konfigurasi pertama

1. Buka Supabase project **Pockito Workspace**.
2. Buka **Project Settings → API**.
3. Salin **Project URL** dan **publishable key** (atau anon/public key lama).
4. Isi nilai tersebut di `web/config.js`.
5. Commit perubahan `config.js`; file ini hanya boleh berisi URL dan public key.
6. Jangan pernah memasukkan `service_role`, database password, atau secret key.

## Menjalankan lokal

Jalankan static server dari root repository, misalnya:

```bash
python -m http.server 8000
```

Buka `http://localhost:8000/web/`.

## Deploy

Workflow `.github/workflows/pages.yml` mengunggah isi folder `web/` ke GitHub Pages setiap ada perubahan pada folder tersebut. Pastikan GitHub Pages di repository diizinkan menggunakan **GitHub Actions** sebagai deployment source.

## Status fitur

- Login, pendaftaran, logout: terhubung ke Supabase Auth.
- Personal/Shared workspace switcher dan role label: terhubung.
- Dashboard, saldo dompet dari ledger, ringkasan bulan ini: terhubung.
- Tambah transaksi income/expense melalui RPC atomik: terhubung.
- Tambah dompet dan kategori: terhubung sesuai RLS.
- Anggaran, target dana, cicilan/kartu, utang/piutang, investasi, transaksi rutin: menu UI sudah tersedia, tetapi operasi CRUD dan detail belum diaktifkan.
- Undangan Shared Workspace, transfer, pembatalan transaksi, laporan lanjutan, notifikasi, dan migrasi data lama: belum diaktifkan.

Jangan masukkan transaksi keuangan penting sebelum pengujian awal selesai. Gunakan data uji kecil terlebih dahulu.
