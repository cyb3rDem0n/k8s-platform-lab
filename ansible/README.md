# ansible/ — provisioning del nodo

Automatizza in modo idempotente ciò che il capitolo 2 del tutorial fa a mano.
La spiegazione riga per riga è in [`docs/tutorial/03-automazione-con-ansible.md`](../docs/tutorial/03-automazione-con-ansible.md).

```bash
python3 -m pip install --user ansible-core      # sul TUO PC, non sul NUC
ansible-galaxy collection install -r requirements.yml
ansible nuc -m ping                              # verifica SSH + sudo
ansible-playbook site.yml --check --diff         # prova a secco: cosa cambierebbe?
ansible-playbook site.yml                        # esegui
```
