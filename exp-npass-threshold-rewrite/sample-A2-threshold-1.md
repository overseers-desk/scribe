---
title: "Our Story"
description: "How a season of jacaranda blossoms, a 5G ban, and a backdoor that nearly broke the internet led to opensource.foundation"
draft: false
---

## The jacarandas were blooming

It was October 2018. I was having coffee at Coomera River, in a scenic café called Historic Rivermill. The trees were in full bloom. The whole river bank turned violet; the blossoms falling so thickly they carpeted the footpaths. The air warm, the light long, everything signalling change.

That spring, something else was changing. Two months earlier, Australia had become the first country in the world to ban Huawei equipment from its 5G networks. The Telecommunications Sector Security Reforms had passed, and the government's assessment was blunt: no technical safeguard could reduce the risk that a vendor might be compelled by a foreign government to act against the interests of its customers.

I was speaking with engineers and managers from Huawei at the time, and with contractors who had been implementing their systems. Many of them felt they were wronged. Their argument was opensource: Huawei's infrastructure ran on open source components, and the company put real effort into contributing back to those projects. The code was open. Anyone could read it. Wasn't that the whole point?

But when I pressed, even the most confident among them admitted something uncomfortable. None of them could say for certain that they were *really* innocent. Their internal version control did not track every fork. When a component was changed for a specific network rollout, it was hard to tell whether the shipped version still matched the published open source code. The code might be open, but the path from open source repository to deployed system was not transparent.

I asked myself a question that stayed with me: *Is this temporary? Will the trust come back once the politics settle?*

## It didn't come back

In May 2019, the United States placed Huawei and 68 affiliates on its restricted-trade list, requiring a government licence for any American company to sell technology to them. In 2020, the rules were tightened to cut Huawei off from advanced chip fabrication, even at overseas factories that used American equipment. What had started as one country's security assessment became a global decoupling.

And it wasn't just China.

In 2019, GitHub, the platform where most of the world's open source lives, began restricting accounts in Iran, Syria, Crimea, and Cuba to comply with US sanctions. Developers who had contributed to open source for years found their private repositories locked overnight, not because of anything they had done, but because of where they lived. In October 2024, the Linux kernel quietly removed eleven Russian maintainers from its MAINTAINERS file. These were people who had maintained drivers and subsystems for years, and the stated reason was "compliance requirements" linked to US sanctions on Russia. When the community protested, Linus Torvalds responded bluntly: the decision stood. Russia's Ministry of Digital Transformation began discussing forking Linux entirely — a sentence that would have read as satire ten years ago.

Meanwhile, RISC-V International, the body governing the open chip architecture, relocated from the United States to Switzerland in 2020, because US export controls could be used to restrict participation. US lawmakers called the move "short-sighted" and pushed for controls on RISC-V itself — controls that would be nearly impossible to enforce on an open standard already published worldwide. In Europe, the Cyber Resilience Act introduced new rules that open source bodies warned could discourage open source software development as a global endeavour. An open letter signed by thirteen organisations, including the Eclipse Foundation and the Open Source Initiative, argued that seventy percent of Europe's software was about to fall under regulation that the people who write it had no say in shaping. The pattern was unmistakable, and no single country or conflict explained it all. US-based foundations found themselves enforcing American sanctions and trade restrictions that limited who could participate — not by choice, but because the law required it. China built its own bodies, including the Open Atom Foundation, which openly aligned itself with state leadership. Russia moved toward sovereign alternatives. Europe added more regulation. Everywhere, the assumption that had sustained open source for decades — that openness alone could build trust, draw talent, and unite the world — was breaking apart along national borders.

Open source is a form. It makes code transparent. But transparent code does not make a trusted organisation, just as a house with no curtains does not make a trusted neighbour. And as rival powers drew harder lines, the gap between "our code is open" and "we are trusted" kept growing.

## The backdoor that proved the point

In March 2024, a Microsoft engineer named Andres Freund noticed that SSH logins on his Debian test system were taking half a second longer than they should. Most people would have muttered something about systemd and moved on. Freund investigated, and uncovered one of the most carefully planned attacks on open source software in its history. A contributor calling himself Jia Tan had spent over two years — patiently, methodically — building trust with Lasse Collin, the Finnish volunteer who single-handedly maintained XZ Utils, a compression library buried in the software that most Linux systems depend on. Collin had publicly spoken about his burnout and mental health struggles. Fake accounts appeared on the project's mailing list, pressuring him to accept help. Gradually, Jia Tan gained co-maintainer access, then full release authority.

In early 2024, Jia Tan inserted a backdoor into XZ Utils. On many Linux systems, the library fed into the SSH login process; anyone holding a specific secret key could silently bypass authentication. Had it not been caught — by chance, because a 400-millisecond delay made one curious engineer dig deeper — it would have shipped in mainstream Linux releases within months, granting silent access to millions of servers worldwide.

No one has proved who "Jia Tan" really was. And the open source model had no way to check: no way to verify who this person was, what institution they represented, or whether their two years of helpful contributions were genuine or preparation for attack. The trust was informal, personal, and nowhere near enough for infrastructure the world depends on.

The XZ incident was a warning I could not ignore. What I had feared the most was now hurting what I loved the most. I had spent my career in open source because I believed in its promise: that transparency builds trust, that shared code builds shared ground, that openness answers suspicion. And here was the proof that the promise, without safeguards, could be used against itself. An unknown attacker had exploited the very culture of openness — the willingness to welcome strangers, the faith in good contributions — to slip malicious code into infrastructure the world depends on.

The XZ incident did not prove that open source is broken. It proved that a layer is missing — a layer of trust that sits above the code and below the politics — and that no one was building it.

I was in Singapore at the time, and with friends who shared the same conviction, we decided to build it ourselves. We considered calling it the "Open Source Trust Foundation," but the name was too long, so we went with `opensource.foundation`. We registered it in 2024, in Singapore, outside any single power's legal reach, with a vision that had been forming, without my quite realising it, since that morning by the river in Coomera.

Not more code transparency. The code was never the problem. What is needed is organisational trust: a neutral body that can check where software comes from, verify who contributed to it, and certify that a project or organisation meets a clear standard of integrity, regardless of where its contributors sit. A place where an engineer in Shenzhen and a maintainer in Helsinki and a regulator in Brussels can all point to the same independent assessment and say: *this is trustworthy, and here is why*.

That is the foundation we are building. It exists because open source deserves better than to have its promise undone by the very divisions it was built to overcome.

---

*Weiwu Zhang is the Chairman of opensource.foundation. He is an Australian citizen of Chinese heritage and has worked in open source technology for over a decade.*
