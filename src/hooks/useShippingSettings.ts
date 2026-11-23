import { useCallback, useEffect, useRef, useState } from 'react'
import { fetchPublicSettings } from '../lib/supabase'
import { getShippingSettings, type ShippingSettings } from '../lib/constants'

export function useShippingSettings() {
  const [settings, setSettings] = useState<ShippingSettings | null>(null)
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState(false)
  const request = useRef(0)

  const refresh = useCallback(async () => {
    const currentRequest = ++request.current
    setLoading(true)
    setError(false)
    try {
      const next = getShippingSettings(await fetchPublicSettings())
      if (currentRequest !== request.current) return null
      setSettings(next)
      setError(!next)
      return next
    } catch {
      if (currentRequest === request.current) {
        setSettings(null)
        setError(true)
      }
      return null
    } finally {
      if (currentRequest === request.current) setLoading(false)
    }
  }, [])

  useEffect(() => {
    void refresh()
    return () => { request.current++ }
  }, [refresh])

  return { settings, loading, error, refresh }
}
