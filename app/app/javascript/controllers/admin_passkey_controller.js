import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["status"]
  static values = {
    registrationOptionsUrl: String,
    registerUrl: String,
    authenticationOptionsUrl: String,
    verifyUrl: String,
    fallbackRedirectUrl: String
  }

  connect() {
    if (!window.PublicKeyCredential) {
      this.setStatus("Seu navegador não oferece suporte a passkeys (WebAuthn).", true)
    }
  }

  async register() {
    try {
      this.setStatus("Iniciando registro da passkey...")
      const options = await this.fetchJson(this.registrationOptionsUrlValue, { method: "POST" })
      const publicKey = this.parseCreationOptions(options)
      const createdCredential = await navigator.credentials.create({ publicKey })

      if (!createdCredential) {
        throw new Error("credential_create_failed")
      }

      const payload = { public_key_credential: createdCredential.toJSON() }
      const result = await this.fetchJson(this.registerUrlValue, {
        method: "POST",
        body: JSON.stringify(payload)
      })

      this.setStatus("Passkey registrada e segundo fator validado com sucesso.")
      this.redirect(result?.data?.redirect_path)
    } catch (error) {
      this.handleError(error, "Falha ao registrar passkey.")
    }
  }

  async verify() {
    try {
      this.setStatus("Solicitando desafio de autenticação...")
      const options = await this.fetchJson(this.authenticationOptionsUrlValue, { method: "POST" })
      const publicKey = this.parseRequestOptions(options)
      const assertion = await navigator.credentials.get({ publicKey })

      if (!assertion) {
        throw new Error("credential_get_failed")
      }

      const payload = { public_key_credential: assertion.toJSON() }
      const result = await this.fetchJson(this.verifyUrlValue, {
        method: "POST",
        body: JSON.stringify(payload)
      })

      this.setStatus("Segundo fator validado com sucesso.")
      this.redirect(result?.data?.redirect_path)
    } catch (error) {
      this.handleError(error, "Falha ao validar passkey.")
    }
  }

  parseCreationOptions(options) {
    if (window.PublicKeyCredential.parseCreationOptionsFromJSON) {
      return window.PublicKeyCredential.parseCreationOptionsFromJSON(options)
    }

    throw new Error("creation_options_parse_not_supported")
  }

  parseRequestOptions(options) {
    if (window.PublicKeyCredential.parseRequestOptionsFromJSON) {
      return window.PublicKeyCredential.parseRequestOptionsFromJSON(options)
    }

    throw new Error("request_options_parse_not_supported")
  }

  async fetchJson(url, options = {}) {
    const response = await fetch(url, {
      credentials: "same-origin",
      headers: {
        "Accept": "application/json",
        "Content-Type": "application/json",
        "X-CSRF-Token": this.csrfToken
      },
      ...options
    })

    const body = await response.json().catch(() => ({}))
    if (!response.ok) {
      const message = body?.error?.message || `HTTP ${response.status}`
      throw new Error(message)
    }

    return body
  }

  get csrfToken() {
    return document.querySelector("meta[name='csrf-token']")?.content || ""
  }

  redirect(path) {
    const destination = path || this.fallbackRedirectUrlValue
    if (destination) {
      window.location.assign(destination)
    }
  }

  handleError(error, fallbackMessage) {
    const message = error?.message || fallbackMessage
    this.setStatus(message, true)
  }

  setStatus(message, isError = false) {
    if (!this.hasStatusTarget) return

    this.statusTarget.textContent = message
    this.statusTarget.style.color = isError ? "var(--danger)" : "var(--text-muted)"
  }
}
