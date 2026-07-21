# InfraOps

InfraOps... because Devs couldn't handle Ops and should never have be allowed to touch production or infrastructure in the first place

## Once upon a time...

### In the olden days, when servers ruled the land...

1. Devs: Fill out an Ops ticket to get their code deployed in production, throwing their new code over the wall at Ops, waiting impatiently
1. Management: Waits impatiently
1. Ops: Installed the new code in production, where the new code breaks production
1. Devs: "Works on my machine..."
1. Management: Pulls their own hair out

### The "DevOps" philosophy (Before containers, Kubernetes, cloud, and scaling FOMO hits)

1. Management: Cries out, "CI/CD unit tests can do quality control!", firing QA
1. Management: Cries out, "Devs can handle Ops!" and wrongly creates the "DevOps Engineer" role (as "DevOps" is a philosophy, not a role) made up of Devs and Ops
1. DevOps Engineers: Do * everything * and get stressed out... Ops learning to code... Devs learning to cope with the responsibility of keeping infrastructure stable

### The "DevOps" philosophy, (After cloud, Kubernetes, containers, and scaling FOMO hits)

1. DevOps Engineers: Devs try to cope with Software Development, Infrastructure as Code, Incident Response, Deployments, Infrastructure, Production...
1. DevOps Engineers: The Devs, not being able to handle the responsibility of keeping Infrastructure stable, get stressed out, start to fall behind in their work, quit...
1. Management: Cries out, "Devs can't handle Ops! Devs, go back to being Devs!", letting the Devs out of "DevOps Engineer" jail
1. Devs: Go back to being Devs
1. Management: Hastily "borrows" Google's "SRE" (Site Reliability Engineer) role idea to deal with incidents and long-term quality control, staffing it with DevOps Engineers
1. Management: Finally realizes that Devs should never have been allowed to touch production infrastructure, but still must be held responsible for the quality of their code in production, and creates the "Platform Engineering" role
1. Platform Engineers: Gives the Devs a shiny, new, production deployment lever
1. Devs: Pulls the deployment lever and their new code goes into production, breaking production
1. SRE: Handles the incident and vows to reduce the frequency of said incident
1. Management: Renames Ops to "Infrastructure Engineers", then cries out,  "Everything must be code!", keeping the DevOps Engineer role around for no good reason

### The Covid "ZIRP" ("Zero Interest Rate Policy" enacted by the Federal Reserve) era ends and the hangover begins...

1. ALL tech management, everywhere: Cries out, "What do you mean, money isn't free anymore?!?", has a panic attack, and hastily enacts a years long hiring freeze
1. Unemployed Ops: Struggle to find Ops jobs, not knowing that their role had been renamed to "Infrastructure Engineer" and "Cloud Engineer"
1. Employed Infrastructure Engineers: Write infrastructure code that creates the reliable, stable, shiny new world of world of clusters (Kubernetes) for stateless applications (containers) in both the cloud and on-prem
1. Infrastructure Engineers: Create the term "InfraOps", drawing a bright dividing line between application code (for Devs only) and infrastructure code (for Ops only)
1. Devs: Fill out an Ops ticket to get new infrastructure
1. Infrastructure Engineers: (Management passes by) Ops scratches their own heads muttering, "You could have just said 'Everything as code!' and left it at that... Don't get me started on the topic of AI psychosis..."
1. Servers: Mutter, "I'm still here. I make your world possible. You can try to ignore me all you like until I break, which I will."
1. Infrastructure Engineers: Fist bumps the servers while saying, "I got you, fam..."

### THE END
