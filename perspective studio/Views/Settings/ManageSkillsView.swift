import SwiftUI
import AppKit

struct ManageSkillsView: View {
    @State private var skillsManager = SkillsManager.shared
    @State private var selectedSkillToInspect: AgentSkill? = nil
    @State private var copiedSkillID: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            // Header Bar
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Manage Skills")
                        .font(.title2)
                        .bold()
                    Text("Skills detected across your local ChatGPT, Claude, and Gemini environments.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button {
                    Task { await skillsManager.scanAllSkills() }
                } label: {
                    HStack(spacing: 6) {
                        if skillsManager.isScanning {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                        Text("Rescan")
                    }
                    .font(.subheadline)
                    .bold()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .disabled(skillsManager.isScanning)
            }

            // Search & Provider Filter Chips
            HStack(spacing: 10) {
                // Search Field in Liquid Glass
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    TextField("Search skills by name, tag, or description...", text: $skillsManager.searchQuery)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))

                    if !skillsManager.searchQuery.isEmpty {
                        Button {
                            skillsManager.searchQuery = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .liquidGlass(.capsule, isClear: true)

                // Source Filter Menu
                Menu {
                    Button("All Sources") {
                        skillsManager.selectedSourceFilter = nil
                    }
                    Divider()
                    ForEach(SkillSource.allCases) { source in
                        Button {
                            skillsManager.selectedSourceFilter = source
                        } label: {
                            HStack {
                                Label(source.rawValue, systemImage: source.icon)
                                if skillsManager.selectedSourceFilter == source {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: skillsManager.selectedSourceFilter?.icon ?? "line.3.horizontal.decrease.circle")
                        Text(skillsManager.selectedSourceFilter?.rawValue ?? "All Sources")
                    }
                    .font(.caption)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .liquidGlass(.capsule)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }

            // Skills Count Summary
            HStack {
                Text("\(skillsManager.filteredSkills.count) skills available")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }

            // Skills Cards List
            if skillsManager.isScanning && skillsManager.skills.isEmpty {
                VStack(spacing: 12) {
                    Spacer()
                    ProgressView("Scanning machine for AI skills...")
                        .controlSize(.regular)
                    Spacer()
                }
                .frame(maxWidth: .infinity, minHeight: 220)
            } else if skillsManager.filteredSkills.isEmpty {
                VStack(spacing: 12) {
                    Spacer()
                    Image(systemName: "sparkles")
                        .font(.system(size: 32))
                        .foregroundStyle(.secondary)
                    Text("No Skills Found")
                        .font(.headline)
                    Text("No skill directories were found matching your search. Try resetting the filter or rescan.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 360)
                    Spacer()
                }
                .frame(maxWidth: .infinity, minHeight: 220)
            } else {
                LazyVStack(spacing: 14) {
                    ForEach(skillsManager.filteredSkills) { skill in
                        skillCard(skill)
                    }
                }
            }
        }
        .sheet(item: $selectedSkillToInspect) { skill in
            skillInspectorSheet(skill)
        }
    }

    // MARK: - Skill Card View (Pure Liquid Glass)

    private func skillCard(_ skill: AgentSkill) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                // Skill Icon
                Image(systemName: skill.source.icon)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(skill.source.brandColor)
                    .frame(width: 36, height: 36)
                    .liquidGlass(.circle)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(skill.name)
                            .font(.system(size: 14, weight: .bold))

                        // Source Badge
                        Text(skill.source.rawValue)
                            .font(.system(size: 10, weight: .semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(skill.source.brandColor.opacity(0.18))
                            .foregroundStyle(skill.source.brandColor)
                            .clipShape(.capsule)
                    }

                    Text(skill.description)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                Spacer()

                // Actions: Inspect Prompt & Copy
                HStack(spacing: 8) {
                    Button {
                        selectedSkillToInspect = skill
                    } label: {
                        Text("View Prompt")
                            .font(.caption)
                            .bold()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Button {
                        copySkillPrompt(skill)
                    } label: {
                        Image(systemName: copiedSkillID == skill.id ? "checkmark" : "doc.on.doc")
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Copy Skill Instructions")
                }
            }

            // Tags Row
            if !skill.tags.isEmpty {
                HStack(spacing: 6) {
                    ForEach(skill.tags, id: \.self) { tag in
                        Text("#\(tag)")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(.leading, 48)
            }
        }
        .padding(14)
        .liquidGlass(.rect(cornerRadius: 16))
    }

    // MARK: - Skill Inspector Sheet

    private func skillInspectorSheet(_ skill: AgentSkill) -> some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 12) {
                    Image(systemName: skill.source.icon)
                        .font(.title2)
                        .foregroundStyle(skill.source.brandColor)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(skill.name)
                            .font(.headline)
                            .bold()
                        Text("Source: \(skill.source.rawValue) • Path: \(skill.folderURL.lastPathComponent)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)

                Divider()

                ScrollView {
                    Text(skill.fullMarkdown)
                        .font(.system(size: 12, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                }
                .liquidGlass(.rect(cornerRadius: 12), isClear: true)
                .padding(.horizontal, 20)
                .padding(.bottom, 16)
            }
            .navigationTitle("Skill Details")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        selectedSkillToInspect = nil
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        copySkillPrompt(skill)
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: copiedSkillID == skill.id ? "checkmark" : "doc.on.doc")
                            Text(copiedSkillID == skill.id ? "Copied" : "Copy Instructions")
                        }
                    }
                }
            }
        }
        .frame(minWidth: 540, minHeight: 460)
    }

    private func copySkillPrompt(_ skill: AgentSkill) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(skill.fullMarkdown, forType: .string)
        withAnimation { copiedSkillID = skill.id }
        Task {
            try? await Task.sleep(for: .seconds(2))
            withAnimation { copiedSkillID = nil }
        }
    }
}
