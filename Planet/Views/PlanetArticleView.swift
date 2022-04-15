//
//  PlanetArticleView.swift
//  Planet
//
//  Created by Kai on 1/15/22.
//

import SwiftUI
import WebKit


struct PlanetArticleView: View {
    @EnvironmentObject private var planetStore: PlanetStore

    var article: PlanetArticle

    @State private var url: URL = Bundle.main.url(forResource: "TemplatePlaceholder.html", withExtension: "")!

    var body: some View {
        VStack {
            if let id = planetStore.selectedArticle, article.id != nil, id == article.id!.uuidString {
                SimplePlanetArticleView(url: $url)
                    .task(priority: .utility) {
                        if let urlPath = PlanetManager.shared.articleURL(article: article) {
                            url = urlPath
                            await PlanetDataController.shared.updateArticleReadStatus(article: article)
                        } else {
                            DispatchQueue.main.async {
                                self.planetStore.currentArticle = nil
                                self.planetStore.selectedArticle = UUID().uuidString
                                self.planetStore.isAlert = true
                                PlanetManager.shared.alertTitle = "Failed to load article"
                                PlanetManager.shared.alertMessage = "Please try again later."
                            }
                        }
                    }
                    .onReceive(NotificationCenter.default.publisher(for: .refreshArticle, object: nil)) { n in
                        if let articleID = n.object as? UUID, let currentArticleID = article.id {
                            guard articleID == currentArticleID else { return }
                            Task.init(priority: .background) {
                                if let urlPath = PlanetManager.shared.articleURL(article: article) {
                                    let now = Int(Date().timeIntervalSince1970)
                                    url = URL(string: urlPath.absoluteString + "?\(now)")!
                                } else {
                                    DispatchQueue.main.async {
                                        self.planetStore.currentArticle = nil
                                        self.planetStore.selectedArticle = UUID().uuidString
                                        self.planetStore.isAlert = true
                                        PlanetManager.shared.alertTitle = "Failed to load article"
                                        PlanetManager.shared.alertMessage = "Please try again later."
                                    }
                                }
                            }
                        }
                    }
            } else {
                Text("No Article Selected")
                    .foregroundColor(.secondary)
            }
        }
    }
}
