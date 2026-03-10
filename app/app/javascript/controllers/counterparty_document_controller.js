import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["kind", "documentLabel", "documentInput", "documentHint", "physicianField"]

  connect() {
    this.sync()
  }

  sync() {
    const physicianSelected = this.kindTarget.value === "PHYSICIAN_PF"

    this.documentLabelTarget.textContent = physicianSelected ? "CPF" : "CNPJ"
    this.documentInputTarget.placeholder = physicianSelected ? "Somente números do CPF" : "Somente números do CNPJ"
    this.documentHintTarget.textContent = physicianSelected ?
      "Médicos PF devem informar um CPF válido." :
      "Hospitais, fornecedores, entidades jurídicas e FDIC devem informar um CNPJ válido."

    this.physicianFieldTargets.forEach((element) => {
      element.hidden = !physicianSelected

      const input = element.querySelector("input, select, textarea")
      if (input) {
        input.disabled = !physicianSelected
      }
    })
  }
}
