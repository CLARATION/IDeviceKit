//
//  Heartbeat+start.swift
//  Feather
//

import Foundation
import UIKit
import OSLog
import IDevice

// MARK: - Class extension: start
extension HeartbeatManager {
	// MARK: - RSD State

	private static var _adapter: AdapterHandle?
	private static var _handshake: RsdHandshakeHandle?

	var adapter: AdapterHandle? {
		get { Self._adapter }
		set { Self._adapter = newValue }
	}

	var handshake: RsdHandshakeHandle? {
		get { Self._handshake }
		set { Self._handshake = newValue }
	}

	// MARK: - Start

	public func start(_ forceRestart: Bool = false) {
		guard !isRsd else {
			return
		}
		
		restartLock.lock()
		defer { restartLock.unlock() }

		restartWorkItem?.cancel()
		restartWorkItem = nil

		if isRestartInProgress && !forceRestart {
			Logger.heartbeat.debug("Restart already in progress, ignoring call")
			return
		}

		let existingThreadIsActive = heartbeatThread?.isExecuting ?? false

		if forceRestart {
			sessionId = arc4random()
			Logger.heartbeat.info("Forcing heartbeat restart with new session ID")

			adapter = nil
			handshake = nil
		} else if existingThreadIsActive {
			Logger.heartbeat.info("Heartbeat thread already running")
			return
		}

		if heartbeatThread != nil && !existingThreadIsActive {
			heartbeatThread = nil
		}

		isRestartInProgress = true

		heartbeatThread = Thread { [weak self] in
			guard let self = self else { return }

			self._establishHeartbeat { [weak self] error in
				guard let self = self else { return }

				self.restartLock.lock()
				defer { self.restartLock.unlock() }

				if let error = error {
					Logger.heartbeat.error("Heartbeat error: \(error.message.pointee)")
					self._scheduleRestart()
				} else {
					self.restartBackoffTime = 1.0
					self.isRestartInProgress = false
				}
			}
		}

		if let thread = heartbeatThread {
			thread.name = "idevice-heartbeat"
			thread.qualityOfService = .background
			thread.start()
			Logger.heartbeat.info("Started new heartbeat thread")
		}
	}

	// MARK: - Restart

	private func _scheduleRestart() {
		let workItem = DispatchWorkItem { [weak self] in
			guard let self = self else { return }

			self.restartLock.lock()
			self.isRestartInProgress = false
			self.restartWorkItem = nil
			self.restartLock.unlock()

			self.start()
		}

		restartWorkItem = workItem
		restartBackoffTime = min(restartBackoffTime * 1.5, 30.0)

		Logger.heartbeat.info("Scheduling restart in \(self.restartBackoffTime) seconds")

		DispatchQueue.main.asyncAfter(
			deadline: .now() + restartBackoffTime,
			execute: workItem
		)
	}

	// MARK: - Establish

	func _establishHeartbeat(
		completion: @escaping (IdeviceFfiError?) -> Void
	) {
		guard let pairingFile = getPairing() else {
			completion(nil)
			return
		}

		sessionId = arc4random()

		if !isRsd {
			guard checkSocketConnection().isConnected else {
				Logger.heartbeat.error("Socket connection failed")
				completion(nil)
				return
			}
		}

		_startHeartbeat(
			pairingFile: pairingFile,
			provider: &provider,
			sessionId: sessionId,
			completion: completion
		)
	}

	// MARK: - RSD Tunnel

	internal func ensureRSDTunnel() -> Bool {
		guard !isRestartInProgress else {
			return true
		}
		
		isRestartInProgress = true
		restartLock.lock()
		defer { restartLock.unlock() }
		
		guard let pairingFile = getPairingRsd() else {
			Logger.heartbeat.error("RSD pairing file not found")
			return false
		}
		
		var addr = sockaddr_in()
		memset(&addr, 0, MemoryLayout.size(ofValue: addr))
		addr.sin_family = sa_family_t(AF_INET)
		addr.sin_port = CFSwapInt16HostToBig(port_rsd)
		
		guard inet_pton(AF_INET, ipAddress, &addr.sin_addr) == 1 else {
			Logger.heartbeat.error("Invalid IP address")
			return false
		}
		
		var newAdapter: AdapterHandle?
		var newHandshake: RsdHandshakeHandle?
		
		print("h")
		
		let result = withUnsafePointer(to: &addr) {
			$0.withMemoryRebound(to: idevice_sockaddr.self, capacity: 1) { ptr in
				tunnel_create_rppairing(
					ptr,
					socklen_t(MemoryLayout<sockaddr_in>.size),
					"IdeviceKit",
					pairingFile,
					nil,
					nil,
					&newAdapter,
					&newHandshake
				)
			}
		}
				
		if let err = result {
			let error = IDeviceSwiftError(err)
			Logger.heartbeat.error("\(error): \(err.pointee.code)")
			return false
		}
				
		if let oldHandshake = handshake {
			rsd_handshake_free(oldHandshake)
		}
		if let oldAdapter = adapter {
			adapter_free(oldAdapter)
		}
		
		adapter = newAdapter
		handshake = newHandshake
		
		rp_pairing_file_free(pairingFile)
		
		isRestartInProgress = false
		
		return true
	}

	// MARK: - Start Heartbeat

	private func _startHeartbeat(
		pairingFile: IdevicePairingFile,
		provider: inout TcpProviderHandle?,
		sessionId: UInt32?,
		completion: @escaping (IdeviceFfiError?) -> Void
	) {
		let currentSession = sessionId

		var addr = sockaddr_in()
		memset(&addr, 0, MemoryLayout.size(ofValue: addr))
		addr.sin_family = sa_family_t(AF_INET)
		addr.sin_port = CFSwapInt16HostToBig(port)
		
		guard inet_pton(AF_INET, ipAddress, &addr.sin_addr) == 1 else {
			Logger.heartbeat.error("Invalid IP address")
			completion(nil)
			return
		}
		
		let result = withUnsafePointer(to: &addr) {
			$0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
				idevice_tcp_provider_new(sockaddrPtr, pairingFile, "SS-Provider", &provider)
			}
		}
		
		if result != nil {
			Logger.heartbeat.error("Failed to create TCP provider")
			completion(result?.pointee)
			return
		}
		
		var heartbeatClient: HeartbeatClientHandle?
		let hbConnectResult = heartbeat_connect(provider, &heartbeatClient)
		
		if hbConnectResult != nil {
			Logger.heartbeat.error("Failed to start heartbeat client")
			completion(nil)
			return
		}
		
		completion(nil)
		
		_runHeartbeatLoop(
			heartbeatClient: heartbeatClient!,
			currentSession: currentSession,
			sessionId: sessionId
		)
	}

	// MARK: - Loop

	private func _runHeartbeatLoop(
		heartbeatClient: HeartbeatClientHandle,
		currentSession: UInt32?,
		sessionId: UInt32?
	) {
		var currentInterval: UInt64 = 15

		while true {
			if sessionId != currentSession {
				break
			}

			var nextInterval: UInt64 = 0

			let marcoResult = heartbeat_get_marco(
				heartbeatClient,
				currentInterval,
				&nextInterval
			)

			if marcoResult != nil {
				Logger.heartbeat.error("heartbeat_get_marco failed")
				heartbeat_client_free(heartbeatClient)
				return
			}

			DispatchQueue.main.async {
				NotificationCenter.default.post(name: .heartbeat, object: nil)
			}

			currentInterval = nextInterval + 5

			let poloResult = heartbeat_send_polo(heartbeatClient)

			if poloResult != nil {
				Logger.heartbeat.error("heartbeat_send_polo failed")
				heartbeat_client_free(heartbeatClient)
				return
			}
		}

		heartbeat_client_free(heartbeatClient)
	}
}
