//! loopdeploy — sign a LoopLab IPA with the user's Apple ID, reusing iloader's stored session.
//!
//! Usage:
//!   loopdeploy sign <in.ipa> <out.ipa> <apple-id> <udid> [anisette-server]
//!
//! The Apple ID password comes from the Windows keyring (service "iloader", account = apple id),
//! which iloader wrote when the user chose to save credentials. The cached development certificate
//! and anisette state are reused from the same store, so a normal run needs no prompts.
//! `increased_memory_limit: true` is what makes the app get ~6 GB instead of ~3.25 GB.

use std::future::Future;
use std::path::PathBuf;
use std::pin::Pin;

use anyhow::{anyhow, Result};
use isideload::anisette::remote_v3::RemoteV3AnisetteProvider;
use isideload::auth::apple_account::{AppleAccount, TwoFactorCallbackParams, TwoFactorCallbackResponse};
use isideload::dev::developer_session::DeveloperSession;
use isideload::sideload::builder::MaxCertsBehavior;
use isideload::sideload::SideloaderBuilder;
use isideload::util::callbacks::MaxCertsCallbackBox;
use isideload::util::keyring_storage::KeyringStorage;

const STORAGE_SERVICE: &str = "iloader";
const MACHINE_NAME: &str = "iloader"; // must match iloader's, so the cached cert identity is reused

/// isideload reports through `rootcause::Report`, which is not `std::error::Error`.
fn rc<T>(r: Result<T, rootcause::Report>, what: &str) -> Result<T> {
    r.map_err(|e| anyhow!("{what}: {e:?}"))
}

/// Apple sends a fresh code for every login attempt, so an agent driving this remotely cannot
/// pass the code up front. Wait for it to appear in a file instead (default `2fa.txt` next to the
/// working directory, override with LOOPDEPLOY_2FA_FILE). Write the code to that file and this
/// callback picks it up within a second or two. `d` = send to devices, `r` = resend; stdin still
/// works when run in a terminal.
fn two_factor_callback(
    params: TwoFactorCallbackParams,
) -> Pin<Box<dyn Future<Output = Result<TwoFactorCallbackResponse, rootcause::Report>> + Send>> {
    Box::pin(async move {
        println!("2FA required: {params:?}");
        let path = std::env::var("LOOPDEPLOY_2FA_FILE")
            .unwrap_or_else(|_| "2fa.txt".to_string());
        let _ = std::fs::remove_file(&path);
        println!("WAITING_FOR_CODE in {path} (write the code there; 10 minute limit)");
        for _ in 0..300 {
            if let Ok(s) = std::fs::read_to_string(&path) {
                let code = s.trim().to_string();
                if !code.is_empty() {
                    let _ = std::fs::remove_file(&path);
                    println!("code received");
                    return Ok(match code.as_str() {
                        "d" => TwoFactorCallbackResponse::SendToDevices,
                        "r" => TwoFactorCallbackResponse::ResendCode,
                        other => TwoFactorCallbackResponse::SubmitCode(other.to_string()),
                    });
                }
            }
            tokio::time::sleep(std::time::Duration::from_secs(2)).await;
        }
        println!("no code appeared in {path}; falling back to stdin");
        let mut code = String::new();
        let _ = std::io::stdin().read_line(&mut code);
        let code = code.trim().to_string();
        Ok(match code.as_str() {
            "d" => TwoFactorCallbackResponse::SendToDevices,
            "r" => TwoFactorCallbackResponse::ResendCode,
            other => TwoFactorCallbackResponse::SubmitCode(other.to_string()),
        })
    })
}

#[tokio::main]
async fn main() -> Result<()> {
    let _ = rustls::crypto::ring::default_provider().install_default();
    tracing_subscriber::fmt().with_max_level(tracing::Level::INFO).init();

    let args: Vec<String> = std::env::args().collect();
    if args.len() < 6 || args[1] != "sign" {
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
    let anisette_url = if anisette.starts_with("http") {
        anisette
    } else {
        format!("https://{anisette}")
    };

    println!("signing {} for {}", in_ipa.display(), udid);

    let password = keyring::Entry::new(STORAGE_SERVICE, &email)
        .map_err(|e| anyhow!("keyring entry: {e}"))?
        .get_password()
        .map_err(|e| anyhow!("no saved Apple ID password for {email} ({e}); open iloader and sign in with \"save credentials\" enabled"))?;
    println!("credentials found for {email}");

    let storage = Box::new(KeyringStorage::new(STORAGE_SERVICE.to_string()));

    let mut account = rc(
        AppleAccount::builder(&email)
            .anisette_provider(
                rc(
                    RemoteV3AnisetteProvider::default()
                        .and_then(|p| Ok(p.set_serial_number("0".to_string()).set_url(&anisette_url))),
                    "anisette",
                )?,
            )
            .login(&password, two_factor_callback)
            .await,
        "Apple ID login",
    )?;
    println!("logged in");

    let dev_session = rc(DeveloperSession::from_account(&mut account).await, "developer session")?;

    let builder: SideloaderBuilder<MaxCertsCallbackBox> = SideloaderBuilder::new(dev_session, email.clone());
    let mut sideloader = builder
        .machine_name(MACHINE_NAME.to_string())
        .storage(storage)
        .max_certs_behavior(MaxCertsBehavior::<MaxCertsCallbackBox>::Revoke)
        .build();

    let progress = |f: f32| {
        println!("  signing {:.0}%", f * 100.0);
        std::future::ready(())
    };
    let (signed_app, _special) = rc(
        sideloader
            .sign_app(in_ipa, None, true, Some(progress), None, Some(&udid))
            .await,
        "signing",
    )?;
    println!("signed app: {}", signed_app.display());

    // Packaging happens in Python (tools/pack_ipa.py): it must preserve unix modes and symlinks and
    // keep the Payload/ prefix, which is easier to get right there. Print the path for the caller.
    println!("SIGNED_APP={}", signed_app.display());
    let _ = &out_ipa; // kept for CLI compatibility
    Ok(())
}
