// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 The Fisher Slopworks Co

import Foundation

struct GitLabProject: Codable, Equatable, Identifiable, Sendable {
    var id: Int
    var name: String
    var path: String
    var webURL: URL
    var cloneURL: URL
    var defaultBranch: String?

    enum CodingKeys: String, CodingKey {
        case id, name
        case path = "path_with_namespace"
        case webURL = "web_url"
        case cloneURL = "http_url_to_repo"
        case defaultBranch = "default_branch"
    }
}

struct GitLabBranch: Codable, Equatable, Sendable {
    var name: String
    var isDefault: Bool

    enum CodingKeys: String, CodingKey {
        case name
        case isDefault = "default"
    }
}

struct GitLabMergeRequest: Codable, Equatable, Sendable {
    struct Author: Codable, Equatable, Sendable {
        var username: String
        var name: String
    }

    var iid: Int
    var projectID: Int
    var title: String
    var author: Author
    var sourceBranch: String
    var targetBranch: String
    var webURL: URL
    var sha: String
    var draft: Bool?
    var workInProgress: Bool?
    var labels: [String]
    var sourceProjectID: Int?

    enum CodingKeys: String, CodingKey {
        case iid, title, author, sha, draft, labels
        case projectID = "project_id"
        case sourceBranch = "source_branch"
        case targetBranch = "target_branch"
        case webURL = "web_url"
        case workInProgress = "work_in_progress"
        case sourceProjectID = "source_project_id"
    }

    var model: MergeRequest {
        MergeRequest(
            projectID: projectID, iid: iid, title: title, author: author.username, sourceBranch: sourceBranch,
            targetBranch: targetBranch, webURL: webURL, sha: sha, draft: draft ?? workInProgress ?? false,
            labels: labels)
    }
}

struct GitLabPipeline: Codable, Equatable, Sendable {
    var id: Int
    var status: String
    var sha: String
    var ref: String?

    var ciStatus: CIPipeline.Status {
        switch status {
        case "success", "skipped", "manual": .passed
        case "failed", "canceled", "canceling": .failed
        default: .running
        }
    }
}

struct GitLabJob: Codable, Equatable, Sendable {
    var id: Int
    var name: String
    var status: String
    var stage: String?
}
