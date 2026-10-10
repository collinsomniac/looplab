//! loopdeploy — sign a LoopLab IPA with the user's Apple ID, reusing iloader's stored session.
//!
//! Usage:
//!   loopdeploy sign <in.ipa> <out.ipa> <apple-id> <udid> [anisette-server]
//!
//! The Apple ID password comes from the Windows keyring (service "iloader", account = apple id),
//! which iloader wrote when the user chose to save credentials. The cached development certificate
//! and anisette state are reused from the same store, so a normal run needs no prompts.
//! `increased_memory_limit: true` is what makes the app get ~6 GB instead of ~3.25 GB.

use std::fs::File;
use std::io::Read;
use std::path::{Path, PathBuf};

use anyhow::{anyhow, Context, Result};
use isideload::anisette::remote_v3::RemoteV3AnisetteProvider;
use isideload::auth::apple_account::{AppleAccount, TwoFactorCallbackParams, TwoFactorCallbackResponse};
use isideload::dev::developer_session::DeveloperSession;
use isideload::sideload::builder::MaxCertsBehavior;
use isideload::sideload::SideloaderBuilder;
use isideload::util::keyring_storage::KeyringStorage;
use walkdir::WalkDir;
use zip::write::SimpleFileOptions;

const STORAGE_SERVICE: &str = "iloader";
const MACHINE_NAME: &str = "iloader"; // must match iloader's, so the cached cert identity is reused

fn two_factor_callback(params: TwoFactorCallbackParams) -> std::future::Ready<Result<TwoFactorCallbackResponse, rootcause::Report>> {
    println!("2FA required: {params:?}");
    println!("Enter the code (or 'd' for devices, 'r' to resend):");
    let mut code = String::new();
    let _ = std::io::stdin().read_line(&mut code);
    let code = code.trim().to_string();
    let resp = match code.as_str() {
        "d" => TwoFactorCallbackResponse::SendToDevices,
        "r" => TwoFactorCallbackResponse::ResendCode,
        other => TwoFactorCallbackResponse::SubmitCode(other.to_string()),
    };
    std::future::ready(Ok(resp))
}

/// Repackage a signed .app into an IPA (Payload/<name>.app/...).
fn zip_app(app_dir: &Path, out: &Path) -> Result<()> {
    let name = app_dir
        .file_name()
        .ok_or_else(|| anyhow!("bad app dir"))?
        .to_string_lossy()
        .to_string();
    let file = File::create(out)?;
    let mut zw = zip::ZipWriter::new(file);
    let opts = SimpleFileOptions::default().compression_method(zip::CompressionMethod::Deflated);
    let mut buf = Vec::new();
    for entry in WalkDir::new(app_dir).min_depth(1) {
        let entry = entry?;
        let rel = entry.path().strip_prefix(app_dir)?;
        let arc = format!("Payload/{name}/{}", rel.to_string_lossy().replace('\\', "/"));
        if entry.file_type().is_dir() {
            zw.add_directory(format!("{arc}/"), opts)?;
        } else {
            buf.clear();
            File::open(entry.path())?.read_to_end(&mut buf)?;
            zw.start_file(arc, opts)?;
            std::io::Write::write_all(&mut zw, &buf)?;
        }
    }
    zw.finish()?;
    Ok(())
}

#[tokio::main]
async fn main() -> Result<()> {
    let _ = rustls::crypto::ring::default_provider().install_default();
    tracing_subscriber::fmt().with_max_level(tracing::Level::INFO).init();

    let args: Vec<String> = std::env::args().collect();
    if args.len() < 6 {
        eprintln!("usage: loopdeploy sign <in.ipa> <out.ipa> <apple-id> <udid> [anisette-server]");
        std::process::exit(2);
    }
    let in_ipa = PathBuf::from(&args[2]);
    let out_ipa = PathBuf::from(&args[3]);
    let email = args[4].to_lowercase();
    let udid = args[5].clone();
    let anisette = args
        .get(6)
        .cloned()
        .unwrap_or_else(|| "https://ani.sidestore.io".to_string());
    let anisette_url = if anisette.starts_with("http") { anisette } else { format!("https://{anisette}") };

    println!("signing {} for {}", in_ipa.display(), udid);

    let password = keyring::Entry::new(STORAGE_SERVICE, &email)
        .context("keyring entry")?
        .get_password()
        .context("no saved Apple ID password for this account (open iloader and sign in with 'save credentials')")?;
    println!("credentials found for {email}");

    let storage = || -> Result<Box<KeyringStorage>> { Ok(Box::new(KeyringStorage::new(STORAGE_SERVICE.to_string()))) };

    let mut account = AppleAccount::builder(&email)
        .anisette_provider(
            RemoteV3AnisetteProvider::default()?
                .set_serial_number("0".to_string())
                .set_storage(storage()?)
                .set_url(&anisette_url),
        )
        .login(&password, two_factor_callback)
        .await
        .context("Apple ID login failed")?;
    println!("logged in");

    let dev_session = DeveloperSession::from_account(&mut account).await.context("developer session")?;

    let mut sideloader = SideloaderBuilder::new(dev_session, email.clone())
        .machine_name(MACHINE_NAME.to_string())
        .storage(storage()?)
        .max_certs_behavior(MaxCertsBehavior::Revoke)
        .build();

    let progress = |f: f32| { print!("\r  signing {:.0}%", f * 100.0); std::future::ready(()) };
    let (signed_app, _special) = sideloader
        .sign_app(in_ipa, None, true, Some(progress), None, Some(&udid))
        .await
        .context("signing failed")?;
    println!("\nsigned app: {}", signed_app.display());

    zip_app(&signed_app, &out_ipa).context("repackaging as IPA")?;
    let size = std::fs::metadata(&out_ipa)?.len();
    println!("wrote {} ({} bytes)", out_ipa.display(), size);
    Ok(())
}
