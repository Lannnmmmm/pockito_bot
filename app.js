
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import {
    SUPABASE_URL,
    SUPABASE_PUBLISHABLE_KEY
} from "./config.js";

const supabase = createClient(
    SUPABASE_URL,
    SUPABASE_PUBLISHABLE_KEY
);

const loginSection = document.getElementById("login-section");
const dashboardSection = document.getElementById("dashboard-section");
const loginForm = document.getElementById("login-form");
const transactionForm = document.getElementById("transaction-form");
const loginMessage = document.getElementById("login-message");
const transactionMessage = document.getElementById("transaction-message");
const transactionList = document.getElementById("transaction-list");

const rupiah = new Intl.NumberFormat("id-ID", {
    style: "currency",
    currency: "IDR",
    maximumFractionDigits: 0
});

let currentUser = null;
let currentWallet = null;

function todayLocal() {
    const now = new Date();
    const year = now.getFullYear();
    const month = String(now.getMonth() + 1).padStart(2, "0");
    const day = String(now.getDate()).padStart(2, "0");

    return `${year}-${month}-${day}`;
}

document.getElementById("transaction-date").value = todayLocal();

function showMessage(element, message, isError = false) {
    element.textContent = message;
    element.style.color = isError ? "#c0392b" : "#4e8b68";
}

function showLogin() {
    loginSection.hidden = false;
    dashboardSection.hidden = true;
}

function showDashboard() {
    loginSection.hidden = true;
    dashboardSection.hidden = false;
}

async function getOrCreateWallet() {
    const { data: wallets, error } = await supabase
        .from("wallets")
        .select("id, name")
        .eq("user_id", currentUser.id)
        .limit(1);

    if (error) throw error;

    if (wallets.length > 0) {
        currentWallet = wallets[0];
        return;
    }

    const { data: wallet, error: createError } = await supabase
        .from("wallets")
        .insert({
            user_id: currentUser.id,
            name: "Dompet Utama",
            balance: 0
        })
        .select("id, name")
        .single();

    if (createError) throw createError;

    currentWallet = wallet;
}

async function loadTransactions() {
    transactionList.replaceChildren();

    const { data: transactions, error } = await supabase
        .from("transactions")
        .select("id, type, amount, description, transaction_date")
        .eq("user_id", currentUser.id)
        .order("transaction_date", { ascending: false })
        .order("created_at", { ascending: false });

    if (error) throw error;

    let totalIncome = 0;
    let totalExpense = 0;

    for (const transaction of transactions) {
        const amount = Number(transaction.amount);

        if (transaction.type === "income") {
            totalIncome += amount;
        } else {
            totalExpense += amount;
        }

        const item = document.createElement("div");
        item.className = "transaction-item";

        const info = document.createElement("div");
        info.className = "transaction-info";

        const description = document.createElement("strong");
        description.textContent =
            transaction.description?.trim() || (
                transaction.type === "income"
                    ? "Pemasukan"
                    : "Pengeluaran"
            );

        const date = document.createElement("small");
        date.textContent = transaction.transaction_date;

        const value = document.createElement("div");
        value.className = `transaction-amount ${
            transaction.type === "income" ? "income" : "expense"
        }`;

        const sign = transaction.type === "income" ? "+" : "−";
        value.textContent = `${sign}${rupiah.format(amount)}`;

        info.append(description, date);
        item.append(info, value);
        transactionList.append(item);
    }

    document.getElementById("total-income").textContent =
        rupiah.format(totalIncome);

    document.getElementById("total-expense").textContent =
        rupiah.format(totalExpense);

    document.getElementById("total-balance").textContent =
        rupiah.format(totalIncome - totalExpense);

    if (transactions.length === 0) {
        const empty = document.createElement("p");
        empty.textContent = "Belum ada transaksi. Yuk, catat transaksi pertamamu!";
        empty.style.color = "#858b81";
        transactionList.append(empty);
    }
}

async function openUserSession(user) {
    currentUser = user;
    currentWallet = null;

    try {
        await getOrCreateWallet();
        await loadTransactions();
        showDashboard();
    } catch (error) {
        console.error("Gagal memuat data:", error);
        showMessage(
            loginMessage,
            "Data belum bisa dimuat. Periksa tabel dan kebijakan RLS Supabase.",
            true
        );
        showLogin();
    }
}

loginForm.addEventListener("submit", async (event) => {
    event.preventDefault();

    const email = document.getElementById("email").value.trim();
    const password = document.getElementById("password").value;
    const submitButton = loginForm.querySelector('button[type="submit"]');

    submitButton.disabled = true;
    showMessage(loginMessage, "Sedang masuk...");

    try {
        const { data, error } = await supabase.auth.signInWithPassword({
            email,
            password
        });

        if (error) throw error;

        await openUserSession(data.user);
    } catch (error) {
        console.error("Login gagal:", error);
        showMessage(
            loginMessage,
            "Login gagal. Periksa email, password, dan koneksi Supabase.",
            true
        );
    } finally {
        submitButton.disabled = false;
    }
});

transactionForm.addEventListener("submit", async (event) => {
    event.preventDefault();

    if (!currentUser || !currentWallet) {
        showMessage(transactionMessage, "Silakan masuk kembali.", true);
        return;
    }

    const type = document.getElementById("transaction-type").value;
    const amount = Number(
        document.getElementById("transaction-amount").value
    );
    const description = document
        .getElementById("transaction-description")
        .value.trim();
    const transactionDate = document.getElementById("transaction-date").value;
    const submitButton = transactionForm.querySelector(
        'button[type="submit"]'
    );

    if (!Number.isFinite(amount) || amount <= 0 || !transactionDate) {
        showMessage(transactionMessage, "Periksa nominal dan tanggal transaksi.", true);
        return;
    }

    submitButton.disabled = true;
    showMessage(transactionMessage, "Menyimpan transaksi...");

    try {
        const { error } = await supabase
            .from("transactions")
            .insert({
                user_id: currentUser.id,
                wallet_id: currentWallet.id,
                type,
                amount,
                description: description || null,
                transaction_date: transactionDate
            });

        if (error) throw error;

        transactionForm.reset();
        document.getElementById("transaction-date").value = todayLocal();
        await loadTransactions();

        showMessage(transactionMessage, "Transaksi berhasil disimpan!");
    } catch (error) {
        console.error("Gagal menyimpan transaksi:", error);
        showMessage(
            transactionMessage,
            "Transaksi gagal disimpan. Periksa koneksi dan kebijakan RLS.",
            true
        );
    } finally {
        submitButton.disabled = false;
    }
});

document.getElementById("logout-button").addEventListener("click", async () => {
    const { error } = await supabase.auth.signOut();

    if (error) {
        console.error("Gagal keluar:", error);
        alert("Gagal keluar. Silakan coba lagi.");
        return;
    }

    currentUser = null;
    currentWallet = null;
    loginForm.reset();
    transactionForm.reset();
    showLogin();
});

async function initializeApp() {
    showLogin();
    showMessage(loginMessage, "Memeriksa sesi...");

    const { data, error } = await supabase.auth.getSession();

    if (error) {
        showMessage(loginMessage, "Gagal memeriksa sesi Supabase.", true);
        return;
    }

    if (data.session?.user) {
        await openUserSession(data.session.user);
    } else {
        showMessage(loginMessage, "");
    }
}

initializeApp();
