//
//  AuthorizationOverlay.swift
//  MirageControliOS
//

import SwiftUI

struct AuthorizationOverlay: View {
    let status: String
    let peerName: String
    let onDisconnect: () -> Void
    
    var body: some View {
        ZStack {
            // Dark elegant backdrop
            Color.black.opacity(0.4)
                .ignoresSafeArea()
            
            VStack(spacing: 24) {
                if status == "pending" {
                    // Pending State
                    Image(systemName: "lock.display")
                        .font(.system(size: 64))
                        .foregroundStyle(.white)
                        .symbolEffect(.pulse, options: .repeating)
                    
                    VStack(spacing: 8) {
                        Text("Waiting for Approval")
                            .font(.title2.bold())
                            .foregroundColor(.white)
                        
                        Text("Please allow the connection request on \(peerName).")
                            .font(.subheadline)
                            .foregroundColor(.gray)
                            .multilineTextAlignment(.center)
                    }
                } else if status == "host_disconnected" {
                    // Host Disconnected State
                    Image(systemName: "wifi.slash")
                        .font(.system(size: 64))
                        .foregroundStyle(.orange)
                    
                    VStack(spacing: 8) {
                        Text("Disconnected")
                            .font(.title2.bold())
                            .foregroundColor(.white)
                        
                        Text("The connection to \(peerName) was closed.")
                            .font(.subheadline)
                            .foregroundColor(.gray)
                            .multilineTextAlignment(.center)
                    }
                } else if status == "denied" {
                    // Denied State
                    Image(systemName: "xmark.shield.fill")
                        .font(.system(size: 64))
                        .foregroundStyle(.red)
                    
                    VStack(spacing: 8) {
                        Text("Access Denied")
                            .font(.title2.bold())
                            .foregroundColor(.white)
                        
                        Text("Your request to control \(peerName) was declined.")
                            .font(.subheadline)
                            .foregroundColor(.gray)
                            .multilineTextAlignment(.center)
                    }
                }
                
                Button(action: onDisconnect) {
                    Text((status == "denied" || status == "host_disconnected") ? "Dismiss" : "Disconnect")
                        .font(.headline)
                        .foregroundColor(.white)
                        .padding(.horizontal, 24)
                        .padding(.vertical, 12)
                        .background(Color.white.opacity(0.15))
                        .clipShape(Capsule())
                }
                .padding(.top, 16)
            }
            .padding(32)
            .background(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(Color(white: 0.15))
                    .shadow(color: .black.opacity(0.3), radius: 20, x: 0, y: 10)
            )
            .padding(.horizontal, 40)
        }
    }
}
