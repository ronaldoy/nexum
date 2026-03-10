import { Controller } from "@hotwired/stimulus"
import { Turbo } from "@hotwired/turbo-rails"

export default class extends Controller {
  static values = { url: String }

  open(event) {
    if (!this.hasUrlValue || this.interactiveTarget(event.target)) {
      return
    }

    if (event.type === "keydown" && !["Enter", " "].includes(event.key)) {
      return
    }

    if (event.type === "keydown") {
      event.preventDefault()
    }

    Turbo.visit(this.urlValue)
  }

  interactiveTarget(target) {
    return target.closest("a, button, input, select, textarea, label, summary, [data-row-link-ignore]")
  }
}
