# Relations

Relations turn records into a network. Eleanor's "Vet" is Dr. Lin Wei. Dr. Lin Wei is a real Person record with their own page; Eleanor's relation to him is a real link, not a label.

## Two flavors

**Property-bound relations.** Some properties are typed `relation` (e.g., `Pets.Vet`, `Events.With`, `Documents.Related to`, `Maintenance.Home`). Each relation property targets a specific database — a Pet's Vet always points at a Person, never a Vehicle. To add a target, click `+ Add` next to the field; a record picker opens scoped to the target database.

**Free-form linked records.** Some records have hand-curated cross-database links not bound to any property. Eleanor, for example, links to her pets, her vehicles, her homes, and a passport. These show up in the **RELATED** section grouped into four canonical quadrants: PETS, VEHICLES, HOMES, DOCUMENTS.

## Backlinks (LINKED FROM)

Below RELATED is a **LINKED FROM** section showing every record that points at this one. Open Dr. Lin Wei → see Juno and Wren under LINKED FROM as their vet relation.

## Removing relations

Right-click a relation chip on a property → **Remove relation**. For free-form linked records, use the same right-click on the chip in the RELATED panel.

## Under the hood

Relations live in their own table. Each row is `(source, target, optional property, type)`. Removing one side doesn't delete the other — only the link.
