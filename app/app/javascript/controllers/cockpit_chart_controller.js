import { Controller } from "@hotwired/stimulus"

const FONT_FAMILY = "\"Inter\", \"Segoe UI\", sans-serif"
const AXIS_COLOR = "#5c6f88"
const LABEL_COLOR = "#17324d"
const FALLBACK_BAR_COLOR = "#2563eb"

export default class extends Controller {
  static targets = ["canvas"]
  static values = { series: Array }

  connect() {
    this.renderWhenReady()
  }

  disconnect() {
    this.clearRetry()
    this.destroyChart()
  }

  renderWhenReady() {
    if (!this.hasCanvasTarget || this.seriesValue.length === 0) return

    if (!window.Chart) {
      this.retryTimer = window.setTimeout(() => this.renderWhenReady(), 50)
      return
    }

    this.clearRetry()
    this.destroyChart()

    const context = this.canvasTarget.getContext("2d")
    if (!context) return

    const series = this.seriesValue
    const formatCurrency = new Intl.NumberFormat("pt-BR", {
      style: "currency",
      currency: "BRL"
    })
    const formatCompactNumber = new Intl.NumberFormat("pt-BR", {
      notation: "compact",
      maximumFractionDigits: 1
    })
    const formatInteger = new Intl.NumberFormat("pt-BR")
    const formatPercent = new Intl.NumberFormat("pt-BR", {
      style: "percent",
      maximumFractionDigits: 1
    })

    this.chart = new window.Chart(context, {
      type: "bar",
      data: {
        labels: series.map((stage) => stage.label),
        datasets: [
          {
            label: "Volume financeiro",
            data: series.map((stage) => stage.volume),
            yAxisID: "y",
            borderSkipped: false,
            borderRadius: 18,
            maxBarThickness: 96,
            borderWidth: 0,
            backgroundColor: (ctx) => this.barGradient(ctx, series[ctx.dataIndex]),
            hoverBackgroundColor: (ctx) => this.barGradient(ctx, series[ctx.dataIndex]),
            barPercentage: 0.72,
            categoryPercentage: 0.74
          }
        ]
      },
      options: {
        responsive: true,
        maintainAspectRatio: false,
        animation: {
          duration: 500,
          easing: "easeOutQuart"
        },
        interaction: {
          mode: "index",
          intersect: false
        },
        layout: {
          padding: {
            top: 8,
            right: 8,
            bottom: 4,
            left: 8
          }
        },
        plugins: {
          legend: { display: false },
          tooltip: {
            backgroundColor: "rgba(10, 22, 40, 0.96)",
            titleColor: "#ffffff",
            bodyColor: "rgba(226, 232, 240, 0.92)",
            borderColor: "rgba(56, 189, 248, 0.18)",
            borderWidth: 1,
            padding: 14,
            displayColors: false,
            callbacks: {
              label: (context) => {
                const stage = series[context.dataIndex]
                return `Volume: ${formatCurrency.format(stage.volume)}`
              },
              afterBody: (items) => {
                const stage = series[items[0].dataIndex]

                return [
                  `Operações: ${formatInteger.format(stage.count)}`,
                  `Participação: ${formatPercent.format(stage.ratio)}`,
                  `Ticket médio solicitado: ${formatCurrency.format(stage.average_ticket)}`
                ]
              }
            }
          }
        },
        scales: {
          x: {
            grid: { display: false, drawBorder: false },
            border: { display: false },
            ticks: {
              color: LABEL_COLOR,
              font: {
                family: FONT_FAMILY,
                size: 12,
                weight: "600"
              }
            }
          },
          y: {
            beginAtZero: true,
            grid: {
              color: "rgba(148, 163, 184, 0.18)",
              drawBorder: false
            },
            border: { display: false },
            ticks: {
              color: AXIS_COLOR,
              font: {
                family: FONT_FAMILY,
                size: 11
              },
              callback: (value) => `R$ ${formatCompactNumber.format(value)}`
            }
          }
        }
      }
    })
  }

  barGradient(context, stage) {
    if (!stage) return FALLBACK_BAR_COLOR

    const chart = context.chart
    const chartArea = chart.chartArea
    if (!chartArea) return stage.tone

    const gradient = chart.ctx.createLinearGradient(0, chartArea.top, 0, chartArea.bottom)
    gradient.addColorStop(0, stage.tone)
    gradient.addColorStop(1, stage.tone_soft)
    return gradient
  }

  destroyChart() {
    if (this.chart) {
      this.chart.destroy()
      this.chart = null
    }
  }

  clearRetry() {
    if (this.retryTimer) {
      window.clearTimeout(this.retryTimer)
      this.retryTimer = null
    }
  }
}
