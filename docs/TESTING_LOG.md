# Pockito Testing Log

Catatan pengujian manual aplikasi Pockito. Hanya pengujian yang telah dikonfirmasi pengguna yang dicatat sebagai **Lulus**.

## 2026-11-06 — Pengujian dasar transaksi dan persistensi saldo

**Status: LULUS**

### Skenario
1. Login ke aplikasi Pockito melalui GitHub Pages.
2. Membuat wallet `BRI Testing` dengan saldo awal Rp100.000.
3. Mencatat transaksi pengeluaran `Tes makan` sebesar Rp15.000.
4. Memeriksa saldo setelah transaksi.
5. Me-refresh halaman, memuat ulang transaksi, lalu memeriksa saldo kembali.

### Hasil yang dikonfirmasi
| Pemeriksaan | Hasil |
|---|---:|
| Saldo awal | Rp100.000 |
| Pengeluaran | Rp15.000 |
| Saldo setelah transaksi | Rp85.000 |
| Saldo setelah refresh dan pemuatan ulang data | Rp85.000 — tetap konsisten |

**Kesimpulan:** pencatatan transaksi dasar dan persistensi saldo setelah refresh berhasil pada skenario pengujian ini.

### Catatan cakupan
Pengujian ini belum membuktikan seluruh skenario ledger, transfer antar-wallet, pembatalan/reversal transaksi, transaksi bersamaan, atau fitur keuangan lainnya. Fitur-fitur tersebut perlu diuji terpisah.

## Format pencatatan berikutnya

Untuk setiap pengujian baru, catat:
- Tanggal pengujian
- Fitur dan skenario
- Data uji
- Hasil yang diharapkan
- Hasil aktual
- Status: Lulus / Gagal / Belum diuji
- Catatan bug atau tindak lanjut
