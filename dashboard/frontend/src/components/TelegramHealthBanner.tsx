import { useEffect, useState } from 'react'
import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query'
import { MessageCircle, AlertTriangle, XCircle, WifiOff, RefreshCw, BellOff, Bell } from 'lucide-react'
import api from '../api/client'

type TelegramHealth = {
  status: 'ok' | 'rate_limited' | 'error' | 'not_configured'
  bot_username: string | null
  retry_after: number
  error: string | null
}

type TeleBroadcastResponse = {
  sent: number
  action: string
  nodes_tg_enabled: boolean
}

type SettingsData = {
  nodes_tg_enabled: boolean
  node_tg_bot_token: string
}

function HealthRow({
  label,
  data,
  onCheck,
  isChecking,
  countdown,
}: {
  label: string
  data: TelegramHealth | undefined
  onCheck: () => void
  isChecking: boolean
  countdown: number
}) {
  if (!data || data.status === 'not_configured') return null

  const cfg = {
    ok: {
      bar: 'bg-green-50 border-green-200',
      dot: 'bg-green-500',
      icon: <MessageCircle size={13} className="text-green-600 shrink-0" />,
      text: `${label}: Hoạt động bình thường${data.bot_username ? ` · ${data.bot_username}` : ''}`,
      textCls: 'text-green-800',
    },
    rate_limited: {
      bar: 'bg-yellow-50 border-yellow-300',
      dot: 'bg-yellow-500 animate-pulse',
      icon: <AlertTriangle size={13} className="text-yellow-600 shrink-0" />,
      text: `${label} bị rate limit (429)${countdown > 0 ? ` · hết hạn sau ${countdown}s` : ''}`,
      textCls: 'text-yellow-800',
    },
    error: {
      bar: 'bg-red-50 border-red-300',
      dot: 'bg-red-500',
      icon: <XCircle size={13} className="text-red-600 shrink-0" />,
      text: `${label} lỗi${data.error ? `: ${data.error}` : ''}`,
      textCls: 'text-red-800',
    },
  }[data.status]

  if (!cfg) return null

  return (
    <div className={`flex items-center gap-2 px-3 py-2 rounded-lg border text-sm ${cfg.bar}`}>
      <span className={`w-2 h-2 rounded-full shrink-0 ${cfg.dot}`} />
      {cfg.icon}
      <span className={`flex-1 font-medium truncate text-xs ${cfg.textCls}`}>{cfg.text}</span>
      {data.status === 'rate_limited' && (
        <span className="text-xs text-yellow-600 bg-yellow-100 border border-yellow-200 px-1.5 py-0.5 rounded-full whitespace-nowrap flex items-center gap-1">
          <WifiOff size={9} />
          Tạm dừng
        </span>
      )}
      <button
        onClick={onCheck}
        disabled={isChecking}
        className="flex items-center gap-1 px-2 py-0.5 text-xs text-gray-400 hover:text-gray-600 hover:bg-white border border-transparent hover:border-gray-200 rounded transition-colors disabled:opacity-40 shrink-0"
        title="Kiểm tra ngay"
      >
        <RefreshCw size={10} className={isChecking ? 'animate-spin' : ''} />
        Kiểm tra
      </button>
    </div>
  )
}

export default function TelegramHealthBanner() {
  const qc = useQueryClient()
  const [countdown1, setCountdown1] = useState(0)
  const [countdown2, setCountdown2] = useState(0)

  // Primary bot health (dashboard)
  const { data: health1, isFetching: f1 } = useQuery<TelegramHealth>({
    queryKey: ['tg-health-primary'],
    queryFn: () => api.get('/settings/telegram-health').then(r => r.data),
    refetchInterval: q => q.state.data?.status === 'rate_limited' ? 10_000 : 60_000,
  })

  // Node bot health (secondary)
  const { data: health2, isFetching: f2 } = useQuery<TelegramHealth>({
    queryKey: ['tg-health-node'],
    queryFn: () => api.get('/settings/telegram-health/node').then(r => r.data),
    refetchInterval: q => q.state.data?.status === 'rate_limited' ? 10_000 : 60_000,
  })

  // Settings (to know nodes_tg_enabled state)
  const { data: settingsData } = useQuery<SettingsData>({
    queryKey: ['settings'],
    queryFn: () => api.get('/settings').then(r => r.data),
    staleTime: 30_000,
  })

  // Live-check mutations
  const check1 = useMutation({
    mutationFn: () => api.post('/settings/telegram-health/check').then(r => r.data),
    onSuccess: () => qc.invalidateQueries({ queryKey: ['tg-health-primary'] }),
  })
  const check2 = useMutation({
    mutationFn: () => api.post('/settings/telegram-health/check/node').then(r => r.data),
    onSuccess: () => qc.invalidateQueries({ queryKey: ['tg-health-node'] }),
  })

  // Broadcast tele-off / tele-on to all nodes
  const broadcast = useMutation({
    mutationFn: (action: 'tele_off' | 'tele_on') =>
      api.post<TeleBroadcastResponse>('/settings/tele-broadcast', { action }).then(r => r.data),
    onSuccess: (res) => {
      qc.invalidateQueries({ queryKey: ['settings'] })
      const verb = res.action === 'tele_off' ? 'TẮT' : 'BẬT'
      alert(`Đã gửi lệnh ${verb} Telegram tới ${res.sent} node.`)
    },
  })

  // Countdown for primary rate limit
  useEffect(() => {
    if (health1?.status !== 'rate_limited') { setCountdown1(0); return }
    setCountdown1(health1.retry_after ?? 0)
    const id = setInterval(() => setCountdown1(p => {
      if (p <= 1) { clearInterval(id); qc.invalidateQueries({ queryKey: ['tg-health-primary'] }); return 0 }
      return p - 1
    }), 1000)
    return () => clearInterval(id)
  }, [health1?.status, health1?.retry_after]) // eslint-disable-line react-hooks/exhaustive-deps

  // Countdown for node rate limit
  useEffect(() => {
    if (health2?.status !== 'rate_limited') { setCountdown2(0); return }
    setCountdown2(health2.retry_after ?? 0)
    const id = setInterval(() => setCountdown2(p => {
      if (p <= 1) { clearInterval(id); qc.invalidateQueries({ queryKey: ['tg-health-node'] }); return 0 }
      return p - 1
    }), 1000)
    return () => clearInterval(id)
  }, [health2?.status, health2?.retry_after]) // eslint-disable-line react-hooks/exhaustive-deps

  const nothingToShow =
    (!health1 || health1.status === 'not_configured') &&
    (!health2 || health2.status === 'not_configured')
  if (nothingToShow) return null

  const nodesEnabled = settingsData?.nodes_tg_enabled ?? true

  return (
    <div className="bg-white border border-gray-200 rounded-xl shadow-sm px-4 py-3 space-y-2">
      {/* Header row */}
      <div className="flex items-center justify-between gap-3">
        <span className="text-xs font-semibold text-gray-500 uppercase tracking-wide flex items-center gap-1.5">
          <MessageCircle size={13} />
          Telegram API Health
        </span>

        {/* Tele-all toggle */}
        <button
          onClick={() => {
            const action = nodesEnabled ? 'tele_off' : 'tele_on'
            const label = nodesEnabled ? 'TẮT thông báo Telegram trên TẤT CẢ node?' : 'BẬT lại thông báo Telegram trên TẤT CẢ node?'
            if (confirm(label)) broadcast.mutate(action)
          }}
          disabled={broadcast.isPending}
          className={`flex items-center gap-1.5 px-3 py-1.5 text-xs font-medium rounded-lg border transition-colors disabled:opacity-50 whitespace-nowrap ${
            nodesEnabled
              ? 'bg-gray-50 border-gray-300 text-gray-700 hover:bg-red-50 hover:border-red-300 hover:text-red-700'
              : 'bg-yellow-50 border-yellow-300 text-yellow-800 hover:bg-green-50 hover:border-green-300 hover:text-green-800'
          }`}
          title={nodesEnabled ? 'Tắt Telegram trên tất cả node' : 'Bật lại Telegram trên tất cả node'}
        >
          {broadcast.isPending
            ? <RefreshCw size={12} className="animate-spin" />
            : nodesEnabled ? <BellOff size={12} /> : <Bell size={12} />
          }
          {nodesEnabled ? 'Tắt TG tất cả node' : 'Bật lại TG tất cả node'}
        </button>
      </div>

      {/* Health rows */}
      <HealthRow
        label="Dashboard Bot"
        data={health1}
        onCheck={() => check1.mutate()}
        isChecking={check1.isPending || f1}
        countdown={countdown1}
      />
      <HealthRow
        label="Node Bot"
        data={health2}
        onCheck={() => check2.mutate()}
        isChecking={check2.isPending || f2}
        countdown={countdown2}
      />

      {/* Nodes tg state indicator */}
      {settingsData && (
        <div className={`flex items-center gap-1.5 text-xs px-1 ${nodesEnabled ? 'text-gray-400' : 'text-yellow-600 font-medium'}`}>
          {nodesEnabled
            ? <><Bell size={11} /> Thông báo node: đang bật</>
            : <><BellOff size={11} /> Thông báo node: đã tắt (lệnh đã gửi tới tất cả node)</>
          }
        </div>
      )}
    </div>
  )
}
